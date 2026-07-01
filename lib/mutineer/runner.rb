# frozen_string_literal: true

require_relative "parser"
require_relative "project"
require_relative "result"
require_relative "isolation"
require_relative "minitest_integration"
require_relative "test_runners"
require_relative "coverage_map"
require_relative "changed_lines"
require_relative "mutator_registry"
require_relative "worker_pool"
require_relative "mutant_id"
require_relative "file_swap"
require_relative "external_backend"
require "set"

module Mutineer
  # Orchestrates one mutation end-to-end: apply it textually, validate the
  # result, select its covering test files from the coverage map, then run only
  # those against the mutated source in an isolated child process (strategy 7a —
  # whole-file reload via `load`).
  #
  # The source file path is passed explicitly because Mutation carries only byte
  # offsets, not its file. M3 replaces M2's hardcoded `test_file:` with coverage-
  # map selection: a mutation whose line no test exercises is :no_coverage (no
  # fork); otherwise exactly the covering test files run in the child.
  class Runner
    # Full Phase B orchestration: resolve operators, discover subjects, build the
    # coverage map, run every mutation, and aggregate. Returns
    # [AggregateResult, source_map]. The CLI then reports + applies the exit code;
    # the integration test asserts directly on the AggregateResult.
    #
    # The parent process `require`s each source file so its classes exist; forked
    # children inherit them, so a covering test file's own require_relative of the
    # source is a no-op and does not clobber the mutated `load` (spec §7).
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [Array(Mutineer::AggregateResult, Hash<String, String>)] aggregate and source map.
    def self.execute(config)
      operator_classes = MutatorRegistry.resolve(config.operators || MutatorRegistry::DEFAULT_NAMES)

      # #27: the external backend runs the suite as a subprocess in the app's own
      # runtime — it does no in-process boot/require or coverage build, so branch
      # before any of that. The in-process path below is untouched.
      return execute_external(config, operator_classes) if config.test_command

      # Boot mode: require the boot file ONCE so the app env (e.g. Rails) is booted
      # in the parent and inherited by every fork. Do NOT manually require the
      # sources — under Zeitwerk a manual require of an autoloadable file raises;
      # the booted env autoloads them, and subject discovery is a static Prism
      # parse that needs nothing loaded. Standalone mode requires the sources as
      # before so their classes exist for the children to inherit.
      if config.boot
        # #7: under --rails an unset RAILS_ENV boots development, where the test
        # suite isn't loaded — coverage comes back empty and EVERY mutant is
        # falsely reported no_coverage (score N/A, exit 0). Default it to test.
        ensure_rails_env(config)

        # Coverage instruments only files loaded AFTER it starts. Start it BEFORE
        # the boot require so the entire app loaded during boot is instrumented;
        # forked children then measure each test's coverage delta against it.
        require "coverage"
        Coverage.start(lines: true) unless Coverage.running?
        require File.expand_path(config.boot, config.project_root)
      else
        config.sources.each { |f| require File.expand_path(f, config.project_root) }
      end
      config.require_paths.each { |f| require File.expand_path(f, config.project_root) }

      if config.boot
        # Rails/Minitest test files do `require "test_helper"`, which needs the
        # test root on $LOAD_PATH (`bin/rails test` adds it). Prepend each test
        # file's helper root here in the parent so loading them in the fork
        # children (both coverage capture and per-mutant) resolves.
        boot_tests = config.tests.map { |t| File.expand_path(t, config.project_root) }
        test_load_roots(boot_tests).each { |d| $LOAD_PATH.unshift(d) unless $LOAD_PATH.include?(d) }

        # Boot mode now uses coverage selection too: capture each test's coverage
        # by forking the booted parent, then select covering tests per mutant.
        coverage_map = CoverageMap.new(
          source_paths: config.sources, test_paths: config.tests,
          cache_dir: config.cache_dir, project_root: config.project_root,
          load_paths: config.load_paths, framework: config.framework,
          boot_path: File.expand_path(config.boot, config.project_root),
          verbose: config.verbose
        ).build_via_fork(rails: config.rails)
      else
        coverage_map = CoverageMap.new(
          source_paths: config.sources, test_paths: config.tests,
          cache_dir: config.cache_dir, project_root: config.project_root,
          load_paths: config.load_paths, framework: config.framework
        ).build_or_load
      end

      # Collect every (subject, mutation) up front so the pool can fan them out.
      jobs, ignored_results, source_map = collect_jobs(config, operator_classes)

      jobs = filter_since(jobs, source_map, config) if config.since

      # C3: 7a writes mutineer_mutant*.rb into each source dir (so require_relative
      # resolves). A SIGKILL'd child skips the tempfile's ensure-unlink, orphaning
      # it. `ensure` is unreliable vs SIGKILL, so the PARENT sweeps each source dir
      # before and after the run — orphans are impossible after a normal run.
      dirs = source_dirs(config)
      sweep_orphans(dirs)

      strategy = config.strategy
      results =
        begin
          framework = config.framework
          # #21: --fail-fast stops scheduling new mutants after the first survivor;
          # in-flight workers drain, unscheduled jobs stay nil (dropped below).
          stop_when = config.fail_fast ? ->(r) { r.survived? } : nil
          bare = WorkerPool.new(config.jobs).run(jobs, stop_when: stop_when) do |subject, mutation|
            run(mutation, source_file: subject.file, coverage_map: coverage_map,
                subject: subject, strategy: strategy, rails: config.rails, framework: framework)
          end
          # The bare Results carry only status (Subjects hold live AST nodes that
          # do not marshal); reattach subject+mutation+id in the parent, in order.
          # filter_map drops nils for jobs --fail-fast left unscheduled.
          bare.each_with_index.filter_map { |r, i| r&.with(subject: jobs[i][0], mutation: jobs[i][1], id: jobs[i][2]) }
        ensure
          sweep_orphans(dirs)
        end

      [AggregateResult.new(results + ignored_results), source_map]
    end

    # Collect every (subject, mutation, id) up front so a backend can run them.
    # #10: a mutant the user marked known-equivalent (inline disable-line comment
    # or .mutineer.yml ignore id) is classified :ignored here and NEVER run — it is
    # removed from the killed+survived denominator so a strong file reaches 100%.
    # The stable id is computed per subject (occurrence needs the full list) and
    # carried on every job so the parent can reattach it after the run. Shared by
    # the in-process and external (#27) backends so job selection can never drift.
    #
    # @return [Array(Array, Array<Result>, Hash<String,String>)] jobs, ignored, source_map.
    def self.collect_jobs(config, operator_classes)
      source_map = {}
      disabled_map = {}
      ignore_set = config.ignore.to_set
      jobs = []
      ignored_results = []
      Project.discover(config.sources, only: config.only).each do |subject|
        source = (source_map[subject.file] ||= File.read(subject.file))
        disabled = (disabled_map[subject.file] ||= suppress_map(source))
        mutations = operator_classes.flat_map { |klass| klass.new.mutations_for(subject, source) }
        ids = MutantId.for_subject(subject, source, mutations)
        mutations.each_with_index do |mutation, i|
          id = ids[i]
          line = source.byteslice(0, mutation.start_offset).count("\n") + 1
          if suppressed?(mutation.operator, line, id, disabled, ignore_set)
            ignored_results << Result.ignored.with(subject: subject, mutation: mutation, id: id)
          else
            jobs << [subject, mutation, id]
          end
        end
      end
      [jobs, ignored_results, source_map]
    end

    # #27: external backend orchestration. Runs each mutant's whole-file mutation on
    # disk (crash-safe swap) and executes the user's --test-command as a subprocess
    # in the app's own runtime. Serial by construction (KTD-5: one shared DB, no
    # per-worker isolation yet). No coverage narrowing — every mutant runs the full
    # --test set (KTD-6); the score is therefore an upper bound and not comparable
    # to an in-process run (the CLI discloses this).
    #
    # @param config [Mutineer::Config] run configuration (test_command set).
    # @param operator_classes [Array<Class>] resolved operators.
    # @return [Array(Mutineer::AggregateResult, Hash<String,String>)] aggregate and source map.
    def self.execute_external(config, operator_classes)
      abs_tests = config.tests.map { |t| File.expand_path(t, config.project_root) }
      dirs      = source_dirs(config)

      # Heal any file a prior hard-killed run left mutated BEFORE reading source —
      # collect_jobs computes mutation offsets/ids from the on-disk bytes, so a
      # still-mutated file would yield garbage offsets against the later-healed
      # source. Heal first, then discover jobs from the clean tree.
      FileSwap.restore_orphans(dirs)

      jobs, ignored_results, source_map = collect_jobs(config, operator_classes)
      jobs = filter_since(jobs, source_map, config) if config.since

      # Calibrate the per-mutant timeout from the clean run (a real suite far
      # outlasts the 10s in-process fork budget), and abort if it isn't green.
      # ponytail: 3x the clean run, floor 30s, ceiling 300s — a heuristic. The
      # floor covers a fast suite; the ceiling bounds a hung mutant (infinite loop)
      # so a handful can't stall a serial run for ~45min on a slow suite.
      smoke_elapsed = ExternalBackend.smoke_check!(config.test_command, abs_tests)
      timeout = [[smoke_elapsed * 3, 30].max, 300].min.ceil

      results = []
      begin
        jobs.each do |subject, mutation, id|
          r = run_external(subject, mutation, config.test_command, abs_tests,
                           timeout: timeout, verbose: config.verbose)
          results << r.with(subject: subject, mutation: mutation, id: id)
          break if config.fail_fast && r.survived? # #21: stop at the first survivor
        end
      ensure
        FileSwap.restore_orphans(dirs)
      end

      [AggregateResult.new(results + ignored_results), source_map]
    end

    # Runs one mutant through the external backend: apply the whole-file mutation on
    # disk, run the command, restore. KTD-8: an invalid (non-reparsing) mutant would
    # fail to load and score a false `killed`, so skip it tool-side (Prism, already
    # cheap) and never write the file — preserving the `skipped` verdict the
    # in-process path gives at runner.rb's pre-fork check.
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

    # Scan a source once into { line_number => :all | Set[operator_syms] } from
    # inline `# mutineer:disable-line [ops]` markers (RuboCop semantics: the marker
    # sits on the same physical line as the code it silences). A bare marker
    # disables every operator on that line; `disable-line a, b` only the listed
    # operators. Block-form disable/enable ranges are intentionally not supported.
    def self.suppress_map(source)
      map = {}
      source.each_line.with_index(1) do |text, line|
        next unless (m = text.match(/#\s*mutineer:disable-line(?:\s+([\w,\s]+))?/))

        ops = m[1]
        map[line] = ops ? ops.split(",").map { |o| o.strip.to_sym }.reject(&:empty?).to_set : :all
      end
      map
    end

    # True when this mutant is suppressed: its line bears a disable-line marker
    # (bare, or scoped to its operator), OR its stable id is in the config ignore
    # list. Checked at job-build time so a suppressed mutant is never forked.
    def self.suppressed?(operator, line, id, disabled, ignore_set)
      return true if ignore_set.include?(id)

      case (entry = disabled[line])
      when :all then true
      when Set  then entry.include?(operator)
      else false
      end
    end

    # --since: keep only jobs whose mutation lands on a line changed since the git
    # ref. Composes with coverage selection (it only narrows the job list; each
    # surviving mutant still goes through Runner.run's coverage check). A file with
    # no changed lines (absent from the diff) contributes no jobs. Line is computed
    # exactly as Runner.run does, from the already-read source in source_map.
    def self.filter_since(jobs, source_map, config)
      changed = ChangedLines.for(ref: config.since, files: config.sources,
                                 project_root: config.project_root)
      jobs.select do |subject, mutation|
        source = source_map[subject.file]
        line = source.byteslice(0, mutation.start_offset).count("\n") + 1
        abs = File.expand_path(subject.file, config.project_root)
        changed.fetch(abs, []).include?(line)
      end
    end

    # For each test file, the directory to add to $LOAD_PATH so its
    # `require "test_helper"` (or spec_helper) resolves: the nearest ancestor
    # holding that helper, plus the file's own dir as a fallback.
    def self.test_load_roots(test_files)
      test_files.flat_map do |f|
        dir = File.dirname(f)
        root = nil
        loop do
          if File.exist?(File.join(dir, "test_helper.rb")) || File.exist?(File.join(dir, "spec_helper.rb"))
            root = dir
            break
          end
          parent = File.dirname(dir)
          break if parent == dir

          dir = parent
        end
        [root, File.dirname(f)].compact
      end.uniq
    end

    # #7: when --rails is on and RAILS_ENV is unset, default it to "test" (and
    # say so) before the app boots — otherwise it boots development and nothing
    # is measured. An explicitly-set RAILS_ENV is always respected.
    def self.ensure_rails_env(config)
      return unless config.rails
      return unless ENV["RAILS_ENV"].nil? || ENV["RAILS_ENV"].empty?

      ENV["RAILS_ENV"] = "test"
      warn "[mutineer] RAILS_ENV was unset; defaulting to 'test' for --rails."
    end

    # The unique absolute directories holding the sources — the sweep target for
    # both orphan mechanisms (in-process mutant tempfiles and external backup
    # files). Shared so the path-expansion rule can't drift between the two paths.
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @return [Array<String>] unique absolute source directories.
    def self.source_dirs(config)
      config.sources.map { |f| File.dirname(File.expand_path(f, config.project_root)) }.uniq
    end

    # Removes stale mutant tempfiles from the given directories.
    #
    # @api private
    # @param dirs [Array<String>] directories to sweep.
    # @return [void]
    def self.sweep_orphans(dirs)
      dirs.each do |dir|
        Dir.glob(File.join(dir, "mutineer_mutant*.rb")).each do |f|
          File.unlink(f) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
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
    # @return [Mutineer::Result] mutant result.
    def self.run(mutation, source_file:, coverage_map: nil, subject: nil, strategy: "reload",
                 timeout: Isolation::DEFAULT_TIMEOUT, rails: false, framework: "minitest")
      source  = File.read(source_file)
      mutated = mutation.apply(source)

      # Validity rule: a mutant that doesn't re-parse is skipped before forking.
      return Result.skipped if Parser.parse_string(mutated).errors.any?

      # Coverage selection (both standalone and boot mode): a mutation on a line
      # no test exercises is :no_coverage (no fork); otherwise exactly the
      # covering test files run in the child.
      line   = source.byteslice(0, mutation.start_offset).count("\n") + 1
      chosen = coverage_map.tests_for(source_file, line)
      # #9/#25: distinguish a genuine coverage gap from a line whose would-be test
      # errored during capture (coverage lost) — the latter is :uncapturable.
      # #25: taint per-METHOD (the mutant's enclosing def range), not whole-file,
      # so a covered method's uncovered line stays :no_coverage while a method
      # reachable only by a failed capture is :uncapturable.
      if chosen.empty?
        # Use the method BODY range, not the whole def: the `def`/`end` lines are
        # "covered" at class-load even when the body never runs, which would mask
        # an uncovered method. body_loc is the body statements' span.
        loc = subject&.body_loc
        range = loc ? (loc.start_line..loc.end_line) : (line..line)
        return coverage_map.method_uncapturable?(source_file, range) ? Result.uncapturable : Result.no_coverage
      end

      abs_tests = chosen.map { |t| File.expand_path(t, coverage_map.project_root) }

      Isolation.run(timeout: timeout) do
        # Forking inherits the parent's live DB connection; sharing one socket
        # across processes corrupts it. Drop it so AR reconnects per child.
        reconnect_active_record if rails
        if strategy == "redefine"
          Isolation.apply_surgical(mutation, subject, source)
        else
          Isolation.apply_whole_file(mutated, source_file)
        end
        TestRunners.for(framework).run(abs_tests)
      end
    end

    # Reconnects ActiveRecord in a forked child when available.
    #
    # @api private
    # @return [void]
    def self.reconnect_active_record
      return unless defined?(ActiveRecord::Base)

      base = ActiveRecord::Base
      # #8: clearing connections here drops an open transactional-fixture
      # transaction, so the test loses its fixture rows and fails. Skip the clear
      # when a transaction is open; otherwise clear (v0.2 per-fork write-safety).
      return if fixture_transaction_open?(base)

      base.connection_handler.clear_all_connections!
    rescue StandardError
      nil
    end
    private_class_method :reconnect_active_record

    # Pure, injectable predicate: true when a transactional-fixture transaction is
    # already open on the connection. Keys off open_transactions (KTD-2) so it is
    # correct whenever the transaction exists, regardless of when it opened. Any
    # probe error degrades safe to false -> caller clears (existing behaviour).
    def self.fixture_transaction_open?(base)
      pool = base.connection_pool
      pool.active_connection? && base.connection.open_transactions.positive?
    rescue StandardError
      false
    end
    private_class_method :fixture_transaction_open?
  end
end
