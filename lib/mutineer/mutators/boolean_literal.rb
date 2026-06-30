# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Boolean literal mutator.
    #
    # Mutates true/false and nil literals in the boolean_literal family.
    class BooleanLiteral < Base
      # Visits true literals.
      #
      # @param node [Prism::TrueNode] node to inspect.
      # @return [void]
      def visit_true_node(node)
        emit(node, "false")
        super
      end

      # Visits false literals.
      #
      # @param node [Prism::FalseNode] node to inspect.
      # @return [void]
      def visit_false_node(node)
        emit(node, "true")
        super
      end

      # Visits nil literals.
      #
      # @param node [Prism::NilNode] node to inspect.
      # @return [void]
      def visit_nil_node(node)
        emit(node, "true")
        super
      end

      private

      # Emits a boolean-literal mutation.
      #
      # @param node [Prism::Node] literal node.
      # @param replacement [String] replacement token.
      # @return [void]
      def emit(node, replacement)
        loc = node.location
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: replacement,
          operator: :boolean_literal
        )
      end
    end
  end
end
