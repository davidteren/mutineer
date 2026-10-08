# frozen_string_literal: true

require "pathname"
require_relative "parser"
require_relative "project"
require_relative "result"
require_relative "isolation"
require_relative "minitest_integration"
require_relative "test_runners"
require_relative "coverage_map"
require_relative "mutator_registry"
require_relative "worker_pool"
require_relative "progress"
require_relative "project_path"
require_relative "file_swap"
require_relative "external_backend"
require_relative "daemon_backend"
require_relative "job_plan"

module Mutineer
  # Orchestrates one mutation end-to-end: apply it textually, validate the
  # result, select its covering test files from the coverage map, then run only
  # those against the mutated source in an isolated child process (strategy
  # whole-file reload via `load`).
  #
  # The source file path is passed explicitly because Mutation carries only byte
  # offsets, not its file. Coverage-map selection replaces a hardcoded test file:
  # a mutation whose line no test exercises is :no_coverage (no fork); otherwise
  # exactly the covering test files run in the child.
  class Runner
    # Full orchestration: resolve operators, discover subjects, build the
    # coverage map, run every mutation, and aggregate. Returns
    # [AggregateResult, source_map, extras], where extras is the hash
    # {JobPlan.collect_jobs} returns (`:legacy_ignore_matches`, `:id_map`), unchanged.
    # The CLI then reports + applies the exit code; the integration test asserts
    # directly on the AggregateResult.
    #
    # The parent process `require`s each source file so its classes exist; forked
    # children inherit them, so a covering test file's own require_relative of the
    # source is a no-op and does not clobber the mutated `load` (spec §7).
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [Array(Mutineer::AggregateResult, Hash<String, String>, Hash)] aggregate,
    #   source map, and run extras.
    def self.execute(config)
      operator_classes = MutatorRegistry.resolve(config.operators || MutatorRegistry::DEFAULT_NAMES)

      # External backend: run the suite as a subprocess in the app's own runtime.
      # It does no in-process boot/require or coverage build, so branch before any
      # of that. The in-process path below is untouched.
      return execute_external(config, operator_classes) if config.test_command

      # Daemon backend: boot the app ONCE in a persistent subprocess under the
      # app's bundle and fork per mutant. Tool-side we only discover jobs + build
      # payloads (Prism), so branch before any in-process boot.
      return DaemonBackend.execute(config, operator_classes) if config.daemon

      # Boot mode: require the boot file ONCE so the app env (e.g. Rails) is booted
      # in the parent and inherited by every fork. Do NOT manually require the
      # sources. Under Zeitwerk a manual require of an autoloadable file raises;
      # the booted env autoloads them, and subject discovery is a static Prism
      # parse that needs nothing loaded. Standalone mode requires the sources as
      # before so their classes exist for the children to inherit.
      if config.boot
        # Under --rails an unset RAILS_ENV boots development, where the test
        # suite is not loaded. Coverage comes back empty and EVERY mutant is
        # falsely reported no_coverage (score N/A, exit 0). Default it to test.
        ensure_rails_env(config)

        # Coverage instruments only files loaded AFTER it starts. Start it BEFORE
        # the boot require so the entire app loaded during boot is instrumented;
        # forked children then measure each test's coverage delta against it.
        # An earlier run in this process leaves Coverage suspended (see below).
        # Coverage a host started is the host's: it is left running.
        require "coverage"
        own_coverage = !Coverage.running?
        case Coverage.state
        when :idle then Coverage.start(lines: true, methods: true)
        when :suspended then Coverage.resume
        end
        require File.expand_path(config.boot, config.project_root)
      else
        config.sources.each { |f| require File.expand_path(f, config.project_root) }
      end
      config.require_paths.each { |f| require File.expand_path(f, config.project_root) }
      preload_owners(config) if config.boot && config.strategy == "redefine"

      if config.boot
        # Rails/Minitest test files do `require "test_helper"`, which needs the
        # test root on $LOAD_PATH (`bin/rails test` adds it). Prepend each test
        # file's helper root here in the parent so loading them in the fork
        # children (both coverage capture and per-mutant) resolves.
        boot_tests = config.tests.map { |t| File.expand_path(t, config.project_root) }
        JobPlan.test_load_roots(boot_tests).each { |d| $LOAD_PATH.unshift(d) unless $LOAD_PATH.include?(d) }

        # Boot mode now uses coverage selection too: capture each test's coverage
        # by forking the booted parent, then select covering tests per mutant.
        coverage_map = CoverageMap.new(
          source_paths: config.sources, test_paths: config.tests,
          cache_dir: File.expand_path(config.cache_dir, config.project_root), project_root: config.project_root,
          load_paths: config.load_paths, framework: config.framework,
          boot_path: File.expand_path(config.boot, config.project_root),
          require_paths: config.require_paths, # loaded above; here only for the cache digest
          verbose: config.verbose,
          capture_timeout: config.capture_timeout || CoverageMap::DEFAULT_CAPTURE_TIMEOUT
        ).build_via_fork(after_fork: (config.rails ? -> { reconnect_active_record } : nil))
        # Nothing reads Coverage once the map is built (cache hit or not), so
        # stop paying for it in every mutant fork (#228).
        Coverage.suspend if own_coverage && Coverage.running?
      else
        # As in boot mode, and with lib first as `rake test` does.
        test_roots = JobPlan.test_load_roots(config.tests.map { |t| File.expand_path(t, config.project_root) })
        libs = config.load_paths.map { |p| File.expand_path(p, config.project_root) }
        $LOAD_PATH.unshift(*(libs + test_roots).uniq.reject { |d| $LOAD_PATH.include?(d) })
        # Relative, so the cache digest does not depend on the checkout path.
        rel_roots = test_roots.map { |d| Pathname(d).relative_path_from(File.expand_path(config.project_root)).to_s }
        coverage_map = CoverageMap.new(
          source_paths: config.sources, test_paths: config.tests,
          cache_dir: File.expand_path(config.cache_dir, config.project_root), project_root: config.project_root,
          load_paths: config.load_paths + rel_roots, framework: config.framework,
          require_paths: config.require_paths,
          capture_timeout: config.capture_timeout || CoverageMap::DEFAULT_CAPTURE_TIMEOUT
        ).build_or_load
      end
      JobPlan.abort_if_unclean!(coverage_map)

      # Collect every (subject, mutation) up front so the pool can fan them out.
      jobs, ignored_results, source_map, extras = JobPlan.collect_jobs(config, operator_classes)

      jobs = JobPlan.scope_since(jobs, source_map, config, extras)

      # Whole-file reload writes mutineer_mutant*.rb into each source dir (so
      # require_relative resolves). A SIGKILL'd child skips the tempfile's
      # ensure-unlink, orphaning it. `ensure` is unreliable vs SIGKILL, so the
      # PARENT sweeps each source dir before and after the run. Orphans are
      # impossible after a normal run.
      dirs = JobPlan.source_dirs(config)
      JobPlan.sweep_orphans(dirs)

      strategy = config.strategy
      # Fail-fast must be serial: a parallel stop_when fires on the first survivor
      # by wall-clock, not input order, so the survivor set would diverge from
      # --jobs 1 (daemon already forces serial for the same reason).
      jobs_n = config.fail_fast ? 1 : config.jobs
      results =
        begin
          framework = config.framework
          stop_when = config.fail_fast ? ->(r) { r.survived? } : nil
          progress  = Progress.new(jobs.size)
          bare = WorkerPool.new(jobs_n).run(jobs, stop_when: stop_when,
                                                  on_result: ->(_r) { progress.tick }) do |subject, mutation|
            run(mutation, source_file: subject.file, coverage_map: coverage_map,
                subject: subject, strategy: strategy, rails: config.rails, framework: framework,
                timeout: config.timeout || Isolation::DEFAULT_TIMEOUT, matrix: config.matrix)
          end
          # The bare Results carry only status (Subjects hold live AST nodes that
          # do not marshal); reattach subject+mutation+id in the parent, in order.
          # filter_map drops nils for jobs --fail-fast left unscheduled.
          share_tests(bare.each_with_index.filter_map do |r, i|
            r = unreported_row(r) if r && config.matrix
            r&.with(subject: jobs[i][0], mutation: jobs[i][1], id: jobs[i][2])
          end)
        ensure
          JobPlan.sweep_orphans(dirs)
        end

      [AggregateResult.new(results + ignored_results), source_map, extras]
    end

    # A `--matrix` error that carries no {Kills} row (the worker crashed, or its
    # result was lost) gets an empty, incomplete row: its tests never reported,
    # so a blind test may have killed it, and the report must say so.
    #
    # @param result [Mutineer::Result] a worker's result.
    # @return [Mutineer::Result]
    def self.unreported_row(result)
      return result unless result.error? && result.kills.nil?

      result.with(kills: Kills.new(killed_by: [], ran: [], complete: false))
    end

    # External backend orchestration. Runs each mutant's whole-file mutation on
    # disk (crash-safe swap) and executes the user's --test-command as a subprocess
    # in the app's own runtime. Serial by construction (one shared DB, no
    # per-worker isolation yet). No coverage narrowing: every mutant runs the full
    # --test set; the score is therefore an upper bound and not comparable to an
    # in-process run (the CLI discloses this).
    #
    # @param config [Mutineer::Config] run configuration (test_command set).
    # @param operator_classes [Array<Class>] resolved operators.
    # @return [Array(Mutineer::AggregateResult, Hash<String,String>, Hash)] aggregate,
    #   source map, and the {JobPlan.collect_jobs} extras.
    def self.execute_external(config, operator_classes)
      abs_tests = config.tests.map { |t| File.expand_path(t, config.project_root) }
      sources   = config.sources.map { |s| FileSwap.canonical_path(File.expand_path(s, config.project_root)) }
      dirs      = sources.map { |s| File.dirname(s) }.uniq

      # Own every source before healing leftovers or reading bytes for mutation.
      # A backup file alone is not ownership; flock is. Canonical paths so
      # symlink aliases of one inode share one lock, independent of cache_dir.
      FileSwap.owning(sources) do
        # Heal any file a prior hard-killed run left mutated BEFORE reading source.
        # collect_jobs computes mutation offsets/ids from the on-disk bytes, so a
        # still-mutated file would yield garbage offsets against the later-healed
        # source. Heal first, then discover jobs from the clean tree.
        FileSwap.restore_orphans(dirs)

        jobs, ignored_results, source_map, extras = JobPlan.collect_jobs(config, operator_classes)
        jobs = JobPlan.scope_since(jobs, source_map, config, extras)

        # Nothing to mutate: return before the smoke check, which runs the whole
        # --test set to calibrate a timeout no mutant would use (#76).
        next [AggregateResult.new(ignored_results), source_map, extras] if jobs.empty?

        # Calibrate the per-mutant timeout from the clean run (a real suite far
        # outlasts the 10s in-process fork budget), and abort if it is not green.
        # 3x the clean run, floor 30s, ceiling 300s: a heuristic. The floor covers
        # a fast suite; the ceiling bounds a hung mutant (infinite loop) so a
        # handful cannot stall a serial run for ~45min on a slow suite.
        smoke_elapsed = ExternalBackend.smoke_check!(config.test_command, abs_tests)
        timeout = [[smoke_elapsed * 3, 30].max, 300].min.ceil

        results = []
        progress = Progress.new(jobs.size)
        begin
          jobs.each do |subject, mutation, id|
            r = run_external(subject, mutation, config.test_command, abs_tests,
                             timeout: timeout, verbose: config.verbose)
            results << r.with(subject: subject, mutation: mutation, id: id)
            progress.tick
            break if config.fail_fast && r.survived? # stop at the first survivor
          end
        ensure
          FileSwap.restore_orphans(dirs)
        end

        [AggregateResult.new(results + ignored_results), source_map, extras]
      end
    end

    # Runs one mutant through the external backend: apply the whole-file mutation
    # on disk, run the command, restore. An invalid (non-reparsing) mutant would
    # fail to load and score a false `killed`, so skip it tool-side (Prism, already
    # cheap) and never write the file, preserving the `skipped` verdict the
    # in-process path gives at the pre-fork check.
    #
    # @return [Mutineer::Result] verdict for this mutant.
    def self.run_external(subject, mutation, command, abs_tests, timeout:, verbose:)
      source  = File.read(subject.file)
      mutated = mutation.apply(source)
      return Result.skipped if Parser.parse_string(mutated).errors.any?

      FileSwap.with(subject.file, mutated) do
        ExternalBackend.run(command, abs_tests, timeout: timeout, verbose: verbose)
      end
    end

    # Loads the class or module of every subject in the booted parent, before
    # the boot coverage is read. Under redefine a child resolves the owner by
    # name ({Isolation.nesting_keywords}), so a lazily loaded class (Zeitwerk,
    # `autoload`) would run its class body there, with the original method,
    # and that run would count as no load at all. Loading it here makes its
    # class-body calls load lines, the same as an eager load. A constant that
    # fails to load stays lazy.
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.preload_owners(config)
      Project.discover(config.sources, only: config.only).each do |subject|
        next if subject.owner_unknown

        Isolation.nesting_keywords(subject.lexical_namespace)
        # The owner itself, as the child resolves it: a Class.new block owner
        # has no lexical namespace.
        Object.const_get(subject.namespace.join("::")) unless subject.namespace.empty?
      rescue StandardError, ScriptError
        nil
      end
    end

    # When --rails is on and RAILS_ENV is unset, default it to "test" (and say so)
    # before the app boots. Otherwise it boots development and nothing is measured.
    # An explicitly-set RAILS_ENV is always respected.
    def self.ensure_rails_env(config)
      return unless config.rails
      return unless ENV["RAILS_ENV"].nil? || ENV["RAILS_ENV"].empty?

      ENV["RAILS_ENV"] = "test"
      warn "[mutineer] RAILS_ENV was unset; defaulting to 'test' for --rails."
    end

    # Runs a single mutation through isolation.
    #
    # @param mutation [Mutineer::Mutation] mutation to run.
    # @param source_file [String] source file path.
    # @param coverage_map [Mutineer::CoverageMap, nil] coverage map.
    # @param subject [Mutineer::Subject, nil] subject for surgical strategy.
    # @param strategy [String] mutation strategy.
    # @param timeout [Integer] child timeout in seconds.
    # @param rails [Boolean] whether Rails reconnect handling is enabled.
    # @param framework [String] test framework name.
    # @param matrix [Boolean] a `--matrix` run: run every covering test and
    #   attach the {Kills} row, with project-relative test files.
    # @return [Mutineer::Result] mutant result.
    def self.run(mutation, source_file:, coverage_map: nil, subject: nil, strategy: "reload",
                 timeout: Isolation::DEFAULT_TIMEOUT, rails: false, framework: "minitest", matrix: false)
      source  = File.read(source_file)
      mutated = mutation.apply(source)

      # Validity rule: a mutant that does not re-parse is skipped before forking.
      return Result.skipped if Parser.parse_string(mutated).errors.any?

      # Coverage selection (both standalone and boot mode): a mutation on a line
      # no test exercises is :no_coverage (no fork); otherwise exactly the
      # covering test files run in the child. Shared with the daemon path so both
      # narrow identically (score parity).
      kind, payload = JobPlan.coverage_selection(source_file, mutation, subject, source, coverage_map)
      return payload if kind == :verdict
      return Result.unplaceable if strategy == "redefine" && subject&.owner_unknown

      abs_tests = payload

      result = Isolation.run(timeout: timeout, channel: matrix) do |channel|
        # Forking inherits the parent's live DB connection; sharing one socket
        # across processes corrupts it. Drop it so AR reconnects per child.
        reconnect_active_record if rails
        if strategy == "redefine"
          Isolation.apply_surgical(mutation, subject, source)
        else
          Isolation.apply_whole_file(mutated, source_file)
        end
        if channel
          # --matrix: every covering test runs, and each outcome goes to the parent.
          TestRunners.for(framework).run(abs_tests, record_to: channel)
        else
          # One failing test already kills the mutant, so the child stops there.
          TestRunners.for(framework).run(abs_tests, stop_at_first_failure: true)
        end
      end
      result = relative_kills(result, coverage_map.project_root)
      JobPlan.load_verdict(result, source_file, mutation, subject, source, coverage_map)
    end

    # Rewrites the test files of a result's {Kills} row relative to the project
    # root, the form the coverage map and the report use. A result without a
    # row comes back unchanged.
    #
    # @api private
    # @param result [Mutineer::Result] a mutant result.
    # @param root [String] project root.
    # @return [Mutineer::Result]
    def self.relative_kills(result, root)
      return result unless (kills = result.kills)

      paths = {}
      rel = lambda do |tests|
        tests.map { |file, name, id| [(paths[file] ||= ProjectPath.relative(file, root)), name, id] }.uniq.sort
      end
      result.with(kills: kills.with(killed_by: rel.call(kills.killed_by), ran: rel.call(kills.ran)))
    end

    # Makes every {Kills} row refer to one shared, frozen array per test. Each
    # row arrives with its own copy of every test it ran, and a large matrix
    # (thousands of mutants times hundreds of tests) would otherwise hold that
    # many copies. Results without a row come back unchanged.
    #
    # A test is its file and its id. The name is display data and can differ
    # between mutants (an RSpec example worded from its matcher reads
    # differently under each mutant), so every row gets the name the first
    # mutant reported, and one example stays one test.
    #
    # @api private
    # @param results [Array<Mutineer::Result>] mutant results.
    # @return [Array<Mutineer::Result>]
    def self.share_tests(results)
      shared = {}
      share = lambda do |tests|
        tests.map { |file, name, id| shared[[file, id]] ||= [file, name, id].map { |s| -s }.freeze }.uniq.sort.freeze
      end
      results.map do |r|
        next r unless (kills = r.kills)

        r.with(kills: kills.with(killed_by: share.call(kills.killed_by), ran: share.call(kills.ran)))
      end
    end

    # Reconnects ActiveRecord in a forked child when available.
    #
    # @api private
    # @return [void]
    def self.reconnect_active_record
      return unless defined?(ActiveRecord::Base)

      base = ActiveRecord::Base
      # Clearing connections here drops an open transactional-fixture
      # transaction, so the test loses its fixture rows and fails. Skip the clear
      # when a transaction is open; otherwise clear (per-fork write-safety).
      return if fixture_transaction_open?(base)

      base.connection_handler.clear_all_connections!
    rescue StandardError
      nil
    end
    private_class_method :reconnect_active_record

    # Pure, injectable predicate: true when a transactional-fixture transaction is
    # already open on the connection. Keys off open_transactions so it is correct
    # whenever the transaction exists, regardless of when it opened. Any probe
    # error degrades safe to false -> caller clears (existing behaviour).
    def self.fixture_transaction_open?(base)
      pool = base.connection_pool
      pool.active_connection? && base.connection.open_transactions.positive?
    rescue StandardError
      false
    end
    private_class_method :fixture_transaction_open?
  end
end
