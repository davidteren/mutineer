# frozen_string_literal: true

require "minitest"
require "stringio"

module Brutus
  # Child-process-only: loads a test file in the current process and runs it
  # programmatically, returning an exit status integer (0 = all passed,
  # 1 = any failure/error).
  #
  # Never call this in the parent — it manipulates global Minitest state
  # (autorun, runnables) that only makes sense in a throwaway forked child.
  #
  # No `rescue` here: Isolation.run's fork block is the single exception
  # boundary (any exception there becomes exit 2). Adding a rescue would create
  # a second exit-2 path and break this method's 0/1 return contract.
  class MinitestIntegration
    # ponytail: tested via runner_test.rb (U6), not in isolation — a direct
    # unit test would require forking and duplicate isolation_test's coverage.
    def self.run(test_file)
      # Neutralise autorun so a test file's `require "minitest/autorun"`
      # registers no at_exit hook.
      def Minitest.autorun; end # rubocop:disable Lint/NestedMethodDefinition

      # Drop runnables inherited from the parent suite (this is the child's
      # private copy — the parent is unaffected) so only the target test runs.
      Minitest::Runnable.reset

      load test_file

      # Silence the child's test output; the parent only cares about pass/fail.
      orig = $stdout
      $stdout = StringIO.new
      passed = Minitest.run([])
      $stdout = orig

      passed ? 0 : 1
    end
  end
end
