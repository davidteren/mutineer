# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Range mutator (Tier-2).
    #
    # Swaps `..` with `...` and `...` with `..`, one mutation per range. The
    # `..` -> `...` mutant survives when no test checks the last element.
    # Flip-flops are FlipFlopNode, not RangeNode, so this mutator skips them.
    #
    # Endless ranges (`1..`, `1..nil`) are skipped. `(1..)` and `(1...)` give
    # the same result for slicing, `include?`, `===`, `size` and patterns, so
    # the mutant is equivalent and no normal test can kill it.
    class RangeLiteral < Base
      # Maps each range operator to its opposite.
      SWAPS = { ".." => "...", "..." => ".." }.freeze

      # Visits range nodes and emits range mutations.
      #
      # @param node [Prism::RangeNode] range node to inspect.
      # @return [void]
      def visit_range_node(node)
        emit(node) unless endless?(node)
        super # nested ranges ((1..2)...(3..4)) each get their own mutation
      end

      private

      # Whether the range has no end: `1..` or `1..nil`.
      #
      # @param node [Prism::RangeNode] range node to inspect.
      # @return [Boolean]
      def endless?(node)
        node.right.nil? || node.right.is_a?(Prism::NilNode)
      end

      # Emits the mutation that swaps the range operator.
      #
      # @param node [Prism::RangeNode] range node to mutate.
      # @return [void]
      def emit(node)
        loc = node.operator_loc
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: SWAPS.fetch(loc.slice),
          operator: :range
        )
      end
    end
  end
end
