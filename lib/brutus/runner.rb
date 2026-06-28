# frozen_string_literal: true

require "tempfile"
require_relative "parser"
require_relative "project"
require_relative "result"
require_relative "isolation"
require_relative "minitest_integration"
require_relative "coverage_map"
require_relative "mutator_registry"

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

      coverage_map = CoverageMap.new(
        source_paths: config.sources, test_paths: config.tests,
        cache_dir: config.cache_dir, project_root: config.project_root,
        load_paths: config.load_paths
      ).build_or_load

      source_map = {}
      results = []
      Project.discover(config.sources, only: config.only).each do |subject|
        source = (source_map[subject.file] ||= File.read(subject.file))
        operator_classes.each do |klass|
          klass.new.mutations_for(subject, source).each do |mutation|
            result = run(mutation, source_file: subject.file, coverage_map: coverage_map)
            results << result.with(subject: subject, mutation: mutation)
          end
        end
      end

      [AggregateResult.new(results), source_map]
    end

    def self.run(mutation, source_file:, coverage_map:, timeout: Isolation::DEFAULT_TIMEOUT)
      source  = File.read(source_file)
      mutated = mutation.apply(source)

      # Validity rule: a mutant that doesn't re-parse is skipped before forking.
      return Result.skipped if Parser.parse_string(mutated).errors.any?

      line       = source[0...mutation.start_offset].count("\n") + 1
      test_files = coverage_map.tests_for(source_file, line)
      return Result.no_coverage if test_files.empty?

      abs_tests = test_files.map { |t| File.expand_path(t, coverage_map.project_root) }

      Isolation.run(timeout: timeout) do
        Tempfile.create(["brutus_mutant", ".rb"]) do |f|
          f.write(mutated)
          f.flush
          load f.path # 7a: reopens the class(es), redefining methods in place
        end
        MinitestIntegration.run(abs_tests)
      end
    end
  end
end
