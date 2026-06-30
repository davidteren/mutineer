# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Condition-negation mutator.
    #
    # Wraps if/unless predicates in `!( ... )` textually.
    class ConditionNegation < Base
      # Visits if nodes.
      #
      # @param node [Prism::IfNode] node to inspect.
      # @return [void]
      def visit_if_node(node)
        wrap(node.predicate)
        super
      end

      # Visits unless nodes.
      #
      # @param node [Prism::UnlessNode] node to inspect.
      # @return [void]
      def visit_unless_node(node)
        wrap(node.predicate)
        super
      end

      private

      # Wraps a predicate in negation.
      #
      # @param predicate [Prism::Node, nil] predicate node.
      # @return [void]
      def wrap(predicate)
        return unless predicate

        loc = predicate.location
        original = @source.byteslice(loc.start_offset...loc.end_offset)
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: "!( #{original} )",
          operator: :condition_negation
        )
      end
    end
  end
end
