# frozen_string_literal: true

require_relative "../minitest_integration"

module Mutineer
  module TestRunners
    # Thin wrapper around the shared Minitest integration runner.
    module Minitest
      # Runs the given Minitest files.
      #
      # @param test_files [String, Array<String>] one file or many files.
      # @return [Integer] 0 on success, 1 on failure.
      def self.run(test_files) = MinitestIntegration.run(test_files)
    end
  end
end
