# frozen_string_literal: true

require_relative "run_seed"
require_relative "minitest_integration/file_order"
require_relative "minitest_integration/stop_at_first_failure"
require_relative "minitest_integration/kill_recorder"
require_relative "minitest_integration/in_test_database_error"

module Mutineer
  # Child-process-only: loads a test file in the current process and runs it
  # programmatically, returning an exit status integer (0 = all passed,
  # 1 = any failure/error, 2 = the first failure was an Active Record
  # connection or lock error).
  #
  # Never call this in the parent — it manipulates global Minitest state
  # (autorun, runnables) that only makes sense in a throwaway forked child.
  #
  # A missing minitest is rescued as FrameworkUnavailable (Isolation.run
  # still turns that raise into exit 2). There is no rescue around the
  # suite run itself: Isolation.run's fork block is the single exception
  # boundary for unexpected errors. Swallowing those here would hide a
  # crash as a verdict. The one 2 this method returns on purpose comes from
  # Minitest's own results: the run's first failing test failed with an
  # Active Record connection or lock error (#296, {InTestDatabaseError}).
  class MinitestIntegration
    # The seed of every Minitest run Mutineer starts, unless `SEED` is set:
    # coverage capture, the clean checks and the mutant runs (#282). The same
    # value is {RunSeed::PINNED_SEED}, which a random RSpec order uses too.
    # Within one file, class order depends only on this seed, so adding
    # another file does not reshuffle it. Files run in the order that run
    # was given. A mutant run's file list is coverage order (paired, then
    # cheapest); the combined clean check uses the order the tests were
    # given. With the stop, the test order can decide `killed` vs `timeout`;
    # a fixed order keeps the verdict stable for a `--baseline` gate. A
    # `--matrix` run uses the same order, so its first failure comes at the
    # same point as the stop's.
    #
    # @api private
    PINNED_SEED = RunSeed::PINNED_SEED

    # The arguments that give `Minitest.run` the shared seed. With `SEED` set,
    # none: Minitest reads `SEED` itself.
    #
    # @api private
    # @return [Array<String>] `["--seed", "1"]`, or `[]` when `SEED` is set.
    def self.seed_args
      ENV["SEED"] ? [] : ["--seed", seed]
    end

    # The seed the Minitest runs use: `SEED` when set, else {PINNED_SEED}.
    #
    # @api private
    # @return [String]
    def self.seed
      ENV.fetch("SEED", PINNED_SEED.to_s)
    end

    # Tested via runner_test.rb, not in isolation — a direct unit test
    # would require forking and duplicate isolation_test's coverage.
    #
    # `test_files` is one path or an Array of paths (coverage selection
    # passes the covering subset); each is loaded before the single
    # Minitest.run.
    #
    # @param test_files [String, Array<String>] one file or many files.
    # @param stop_at_first_failure [Boolean] end the run at the first failing
    #   test. Only the mutant path passes true.
    # @param record_to [IO, nil] a `--matrix` run: send each test's outcome to
    #   this channel (see {KillRecorder}) and run every test.
    # @return [Integer] 0 on success, 1 on failure, 2 when the first failure
    #   was an Active Record connection or lock error (see {InTestDatabaseError}).
    # @raise [ArgumentError] when both options are given: a matrix run never stops.
    def self.run(test_files, stop_at_first_failure: false, record_to: nil)
      if stop_at_first_failure && record_to
        raise ArgumentError, "stop_at_first_failure and record_to cannot be combined: a matrix run runs every test"
      end

      begin
        require "minitest"
      rescue LoadError
        raise Mutineer::FrameworkUnavailable,
              "minitest is not available — add minitest to the project under test, " \
              "or use --framework rspec"
      end

      # minitest is required LAZILY (never at load time) so Mutineer keeps
      # zero runtime gem deps and loads fine in an rspec-only project; a missing
      # minitest raises a clear Mutineer error rather than a LoadError backtrace.

      # Neutralise autorun so a test file's `require "minitest/autorun"`
      # registers no at_exit hook.
      def Minitest.autorun; end # rubocop:disable Lint/NestedMethodDefinition

      # Drop runnables inherited from the parent suite (this is the child's
      # private copy — the parent is unaffected) so only the target test runs.
      Minitest::Runnable.reset
      # Each test class's file position: the file that first defined it.
      rank = {}
      Array(test_files).each_with_index do |f, i|
        load f
        Minitest::Runnable.runnables.each { |klass| rank[klass] ||= i }
      end

      if record_to
        KillRecorder.arm!(record_to, Minitest::Runnable.runnables)
      elsif stop_at_first_failure
        StopAtFirstFailure.arm!(Minitest::Runnable.runnables)
      end
      # An unknown Minitest shape arms no hook and gets a full run, in the
      # same seeded file order as a clean check (#282).
      keep_file_order(rank)
      # On its own line, not inside the stop or matrix branch. Folding it
      # in would tie the database-error hook to those hooks (#296).
      InTestDatabaseError.arm!
      # No silencing here: the fork boundary that calls this method has already
      # pointed stdout at File::NULL (see ChildStdout).
      passed = Minitest.run(seed_args)
      # Reached only when the suite returned: a test that exits the process
      # skips it, and the parent then keeps the row incomplete.
      KillRecorder.finish! if record_to

      # A plugin can replace the summary reporter, so a stop decides by itself.
      code = passed && !StopAtFirstFailure.stopped_here? ? 0 : 1
      InTestDatabaseError.exit_code(code)
    ensure
      StopAtFirstFailure.disarm!
      KillRecorder.disarm!
      InTestDatabaseError.disarm!
    end

  end
end
