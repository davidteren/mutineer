# frozen_string_literal: true

require_relative "parser"

module Mutineer
  # One atomic byte-range edit.
  #
  # Immutable. One mutation per mutant — never combine. Source is mutated
  # textually, never regenerated from the AST.
  Mutation = Data.define(:start_offset, :end_offset, :replacement, :operator) do
    # Applies the mutation to source text.
    #
    # @param source [String] original source text.
    # @return [String] mutated source text.
    def apply(source)
      source.byteslice(0, start_offset) + replacement + source.byteslice(end_offset..)
    end

    # Checks whether the running Ruby can still load the mutated source (see
    # {Parser.invalid?}).
    #
    # @param source [String] original source text.
    # @return [Boolean] true when the mutated source re-parses.
    def valid?(source)
      !Parser.invalid?(apply(source))
    end
  end
end
