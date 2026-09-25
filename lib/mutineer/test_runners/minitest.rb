# frozen_string_literal: true

require_relative "../minitest_integration"

module Mutineer
  module TestRunners
    # Thin wrapper around the shared Minitest integration runner.
    module Minitest
      # Runs the given Minitest files.
      #
      # @param test_files [String, Array<String>] one file or many files.
      # @param stop_at_first_failure [Boolean] when true, the run ends at the
      #   first failing test.
      # @return [Integer] 0 on success, 1 on failure.
      def self.run(test_files, stop_at_first_failure: false)
        MinitestIntegration.run(test_files, stop_at_first_failure: stop_at_first_failure)
      end
    end
  end
end
