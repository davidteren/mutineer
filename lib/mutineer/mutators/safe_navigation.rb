# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Safe-navigation mutator (Tier-2).
    #
    # Replaces `&.` with `.`, one mutation per occurrence. The mutant raises
    # NoMethodError on a nil receiver, so it survives when no test passes nil.
    class SafeNavigation < Base
      # Visits call nodes and emits safe-navigation mutations.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        emit(node)
        super # chained calls (a&.b&.c) each get their own mutation
      end

      # Visits `a&.b += 1`, which Prism parses as its own node, not a CallNode.
      #
      # @param node [Prism::CallOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_call_operator_write_node(node)
        emit(node)
        super
      end

      # Visits `a&.b ||= 1`.
      #
      # @param node [Prism::CallOrWriteNode] node to inspect.
      # @return [void]
      def visit_call_or_write_node(node)
        emit(node)
        super
      end

      # Visits `a&.b &&= 1`.
      #
      # @param node [Prism::CallAndWriteNode] node to inspect.
      # @return [void]
      def visit_call_and_write_node(node)
        emit(node)
        super
      end

      # Visits a call used as an assignment target, as in `for a&.b in list`.
      #
      # @param node [Prism::CallTargetNode] node to inspect.
      # @return [void]
      def visit_call_target_node(node)
        emit(node)
        super
      end

      private

      # Emits a mutation when the node's call operator is `&.`.
      #
      # @param node [Prism::Node] a node with `safe_navigation?` and `call_operator_loc`.
      # @return [void]
      def emit(node)
        return unless node.safe_navigation?

        loc = node.call_operator_loc
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: ".",
          operator: :safe_navigation
        )
      end
    end
  end
end
