# frozen_string_literal: true

require_relative "minitest_integration/stop_at_first_failure"
require_relative "minitest_integration/kill_recorder"

module Mutineer
  # Child-process-only: loads a test file in the current process and runs it
  # programmatically, returning an exit status integer (0 = all passed,
  # 1 = any failure/error).
  #
  # Never call this in the parent — it manipulates global Minitest state
  # (autorun, runnables) that only makes sense in a throwaway forked child.
  #
  # A missing minitest is rescued as FrameworkUnavailable (Isolation.run
  # still turns that raise into exit 2). There is no rescue around the
  # suite run itself: Isolation.run's fork block is the single exception
  # boundary for unexpected errors. Swallowing those here would create a
  # second exit-2 path and break this method's 0/1 return contract.
  class MinitestIntegration
    # The seed of a mutant run (one that stops at the first failure, or a
    # `--matrix` run that records every test), unless `SEED` is set. With the
    # stop, the test order can decide `killed` vs `timeout`; a fixed order keeps
    # the verdict stable for a `--baseline` gate. A matrix run uses the same
    # order, so its first failure comes at the same point as the stop's.
    STOP_AT_FIRST_FAILURE_SEED = 1

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
    # @return [Integer] 0 on success, 1 on failure.
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
      Array(test_files).each { |f| load f }

      armed =
        if record_to
          KillRecorder.arm!(record_to)
        elsif stop_at_first_failure
          StopAtFirstFailure.arm!(Minitest::Runnable.runnables)
        end
      # Pin the seed only when a hook is armed; an unknown Minitest shape gets
      # the normal full, randomly ordered run.
      args = armed && !ENV["SEED"] ? ["--seed", STOP_AT_FIRST_FAILURE_SEED.to_s] : []
      # No silencing here: the fork boundary that calls this method has already
      # pointed stdout at File::NULL (see ChildStdout).
      passed = Minitest.run(args)

      # A plugin can replace the summary reporter, so a stop decides by itself.
      passed && !StopAtFirstFailure.stopped_here? ? 0 : 1
    ensure
      StopAtFirstFailure.disarm!
      KillRecorder.disarm!
    end
  end
end
