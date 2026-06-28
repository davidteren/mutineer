# frozen_string_literal: true

require_relative "parser"

module Mutineer
  # One atomic byte-range edit. Immutable. One mutation per mutant — never
  # combine. Source is mutated textually, never regenerated from the AST.
  Mutation = Data.define(:start_offset, :end_offset, :replacement, :operator) do
    # Pure: returns a new string, does not mutate `source`. Prism offsets are
    # BYTE offsets, so all slicing is byte-based (byteslice) — char slicing would
    # corrupt any source containing a multibyte char before the mutation point.
    def apply(source)
      source.byteslice(0, start_offset) + replacement + source.byteslice(end_offset..)
    end

    # Validity rule: a mutation is valid iff the mutated source re-parses clean.
    def valid?(source)
      Parser.parse_string(apply(source)).errors.empty?
    end
  end
end
