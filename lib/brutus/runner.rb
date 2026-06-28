# frozen_string_literal: true

require "tempfile"
require_relative "parser"
require_relative "result"
require_relative "isolation"
require_relative "minitest_integration"

module Brutus
  # Orchestrates one mutation end-to-end: apply it textually, validate the
  # result, then run the given test file against the mutated source in an
  # isolated child process (strategy 7a — whole-file reload via `load`).
  #
  # The source file path is passed explicitly because M1's Mutation carries
  # only byte offsets, not its file. M3 will replace the explicit `test_file:`
  # argument with coverage-map selection.
  class Runner
    def self.run(mutation, source_file:, test_file:, timeout: Isolation::DEFAULT_TIMEOUT)
      source  = File.read(source_file)
      mutated = mutation.apply(source)

      # Validity rule: a mutant that doesn't re-parse is skipped before forking.
      return Result.skipped if Parser.parse_string(mutated).errors.any?

      Isolation.run(timeout: timeout) do
        Tempfile.create(["brutus_mutant", ".rb"]) do |f|
          f.write(mutated)
          f.flush
          load f.path # 7a: reopens the class(es), redefining methods in place
        end
        MinitestIntegration.run(test_file)
      end
    end
  end
end
