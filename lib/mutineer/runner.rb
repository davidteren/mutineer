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
    def self.execute(config)
      operator_classes = MutatorRegistry.resolve(config.operators || MutatorRegistry::DEFAULT_NAMES)

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
          boot_path: File.expand_path(config.boot, config.project_root)
        ).build_via_fork(rails: config.rails)
      else
        coverage_map = CoverageMap.new(
          source_paths: config.sources, test_paths: config.tests,
          cache_dir: config.cache_dir, project_root: config.project_root,
          load_paths: config.load_paths, framework: config.framework
        ).build_or_load
      end

      # Collect every (subject, mutation) up front so the pool can fan them out.
      source_map = {}
      jobs = []
      Project.discover(config.sources, only: config.only).each do |subject|
        source = (source_map[subject.file] ||= File.read(subject.file))
        operator_classes.each do |klass|
          klass.new.mutations_for(subject, source).each do |mutation|
            jobs << [subject, mutation]
          end
        end
      end

      jobs = filter_since(jobs, source_map, config) if config.since

      # C3: 7a writes mutineer_mutant*.rb into each source dir (so require_relative
      # resolves). A SIGKILL'd child skips the tempfile's ensure-unlink, orphaning
      # it. `ensure` is unreliable vs SIGKILL, so the PARENT sweeps each source dir
      # before and after the run — orphans are impossible after a normal run.
      source_dirs = config.sources
                          .map { |f| File.dirname(File.expand_path(f, config.project_root)) }.uniq
      sweep_orphans(source_dirs)

      strategy = config.strategy
      results =
        begin
          framework = config.framework
          bare = WorkerPool.new(config.jobs).run(jobs) do |subject, mutation|
            run(mutation, source_file: subject.file, coverage_map: coverage_map,
                subject: subject, strategy: strategy, rails: config.rails, framework: framework)
          end
          # The bare Results carry only status (Subjects hold live AST nodes that
          # do not marshal); reattach subject+mutation in the parent, in order.
          bare.each_with_index.map { |r, i| r.with(subject: jobs[i][0], mutation: jobs[i][1]) }
        ensure
          sweep_orphans(source_dirs)
        end

      [AggregateResult.new(results), source_map]
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

    def self.sweep_orphans(dirs)
      dirs.each do |dir|
        Dir.glob(File.join(dir, "mutineer_mutant*.rb")).each do |f|
          File.unlink(f) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
    end

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
      return Result.no_coverage if chosen.empty?

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

    def self.reconnect_active_record
      return unless defined?(ActiveRecord::Base)

      ActiveRecord::Base.connection_handler.clear_all_connections!
    rescue StandardError
      nil
    end
    private_class_method :reconnect_active_record
  end
end
