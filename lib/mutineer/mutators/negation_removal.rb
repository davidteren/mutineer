# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Negation-removal mutator (Tier-2).
    #
    # Removes the `!` or `not` of a negation, one mutation per occurrence:
    # `!x` becomes `x` and `not x` becomes ` x`. The mutant survives when no
    # test depends on the negated value.
    class NegationRemoval < Base
      # Visits call nodes and emits negation-removal mutations.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        emit(node)
        super # nested negations (!!x) each get their own mutation
      end

      private

      # Emits a mutation when the node is a prefix `!` or `not`.
      #
      # The explicit form `x.!` is skipped: without its message, `x.` does
      # not parse.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def emit(node)
        return unless node.name == :! && node.call_operator_loc.nil?

        loc = node.message_loc
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: "",
          operator: :negation_removal
        )
      end
    end
  end
end
