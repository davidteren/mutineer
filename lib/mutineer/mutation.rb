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
      # An ASCII replacement is retagged so it concatenates with a source
      # whose magic comment names another encoding (EUC-JP, Shift_JIS).
      # The bytes do not change, so the file Ruby loads stays in that encoding.
      repl = replacement
      repl = repl.dup.force_encoding(source.encoding) if repl.ascii_only? && repl.encoding != source.encoding
      source.byteslice(0, start_offset) + repl + source.byteslice(end_offset..)
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
