# frozen_string_literal: true

require_relative "../minitest_integration"

module Mutineer
  module TestRunners
    # Uniform wrapper over the existing MinitestIntegration impl so the runner
    # selection (TestRunners.for) has one method shape across frameworks.
    # MinitestIntegration stays the implementation — all its behaviour (autorun
    # neutralisation, Runnable.reset, load, Minitest.run -> 0/1) is preserved.
    module Minitest
      def self.run(test_files) = MinitestIntegration.run(test_files)
    end
  end
end
