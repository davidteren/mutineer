# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Arithmetic operator mutator.
    #
    # One mutation per occurrence, rewriting the operator token.
    class Arithmetic < Base
      # Token replacements for arithmetic operators.
      REPLACEMENTS = {
        :+ => "-", :- => "+", :* => "/", :/ => "*", :% => "*", :** => "*"
      }.freeze

      # Visits call nodes and emits arithmetic mutations.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        replacement = REPLACEMENTS[node.name]
        loc = node.message_loc
        if replacement && loc
          @mutations << Mutation.new(
            start_offset: loc.start_offset,
            end_offset: loc.end_offset,
            replacement: replacement,
            operator: :arithmetic
          )
        end
        super # nested calls (e.g. a + (b * c)) each get their own mutation
      end
    end
  end
end
