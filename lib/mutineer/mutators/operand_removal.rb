# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Operand-removal mutator (Tier-2).
    #
    # Replaces a boolean expression with one of its operands, two mutations
    # per `&&`, `||`, `and` or `or`: `a && b` becomes `(a)` and `(b)`. The
    # parentheses keep the precedence of `and` and `or`. A surviving mutant
    # shows that no test needs the operand that was removed.
    class OperandRemoval < Base
      # Node types for jumps. A jump in a value context does not parse, so
      # the operator never keeps a jump alone.
      JUMPS = [Prism::ReturnNode, Prism::BreakNode, Prism::NextNode, Prism::RedoNode, Prism::RetryNode].freeze

      # Visits `and` nodes.
      #
      # @param node [Prism::AndNode] node to inspect.
      # @return [void]
      def visit_and_node(node)
        emit(node)
        super # nested connectors (a && b && c) each get their own mutations
      end

      # Visits `or` nodes.
      #
      # @param node [Prism::OrNode] node to inspect.
      # @return [void]
      def visit_or_node(node)
        emit(node)
        super
      end

      private

      # Emits one mutation that keeps the left operand, then one that keeps
      # the right operand. The order is fixed, because the two mutants share
      # a token and their occurrence ordinals tell them apart.
      #
      # @param node [Prism::AndNode, Prism::OrNode] connector node.
      # @return [void]
      def emit(node)
        [[node.left, node.right], [node.right, node.left]].each do |kept, removed|
          next if JUMPS.any? { |type| kept.is_a?(type) } || heredoc?(removed)

          @mutations << Mutation.new(
            start_offset: node.location.start_offset,
            end_offset: node.location.end_offset,
            replacement: "(#{kept.slice})",
            operator: :operand_removal
          )
        end
      end
    end
  end
end
