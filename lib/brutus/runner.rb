# frozen_string_literal: true

require_relative "parser"
require_relative "project"
require_relative "result"
require_relative "isolation"
require_relative "minitest_integration"
require_relative "coverage_map"
require_relative "mutator_registry"
require_relative "worker_pool"

module Brutus
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
      config.sources.each { |f| require File.expand_path(f, config.project_root) }
      config.require_paths.each { |f| require File.expand_path(f, config.project_root) }

      coverage_map = CoverageMap.new(
        source_paths: config.sources, test_paths: config.tests,
        cache_dir: config.cache_dir, project_root: config.project_root,
        load_paths: config.load_paths
      ).build_or_load

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

      # C3: 7a writes brutus_mutant*.rb into each source dir (so require_relative
      # resolves). A SIGKILL'd child skips the tempfile's ensure-unlink, orphaning
      # it. `ensure` is unreliable vs SIGKILL, so the PARENT sweeps each source dir
      # before and after the run — orphans are impossible after a normal run.
      source_dirs = config.sources
                          .map { |f| File.dirname(File.expand_path(f, config.project_root)) }.uniq
      sweep_orphans(source_dirs)

      strategy = config.strategy
      results =
        begin
          bare = WorkerPool.new(config.jobs).run(jobs) do |subject, mutation|
            run(mutation, source_file: subject.file, coverage_map: coverage_map,
                subject: subject, strategy: strategy)
          end
          # The bare Results carry only status (Subjects hold live AST nodes that
          # do not marshal); reattach subject+mutation in the parent, in order.
          bare.each_with_index.map { |r, i| r.with(subject: jobs[i][0], mutation: jobs[i][1]) }
        ensure
          sweep_orphans(source_dirs)
        end

      [AggregateResult.new(results), source_map]
    end

    def self.sweep_orphans(dirs)
      dirs.each do |dir|
        Dir.glob(File.join(dir, "brutus_mutant*.rb")).each do |f|
          File.unlink(f) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
    end

    def self.run(mutation, source_file:, coverage_map:, subject: nil, strategy: "7a",
                 timeout: Isolation::DEFAULT_TIMEOUT)
      source  = File.read(source_file)
      mutated = mutation.apply(source)

      # Validity rule: a mutant that doesn't re-parse is skipped before forking.
      return Result.skipped if Parser.parse_string(mutated).errors.any?

      line       = source.byteslice(0, mutation.start_offset).count("\n") + 1
      test_files = coverage_map.tests_for(source_file, line)
      return Result.no_coverage if test_files.empty?

      abs_tests = test_files.map { |t| File.expand_path(t, coverage_map.project_root) }

      Isolation.run(timeout: timeout) do
        if strategy == "7b"
          Isolation.apply_surgical(mutation, subject, source)
        else
          Isolation.apply_whole_file(mutated, source_file)
        end
        MinitestIntegration.run(abs_tests)
      end
    end
  end
end
