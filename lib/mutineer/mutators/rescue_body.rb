# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Rescue-body mutator (Tier-2, #418).
    #
    # Replaces the whole body of each `rescue` clause with `nil`, and the
    # value of a rescue modifier (`x rescue y` becomes `x rescue nil`). The
    # mutant survives when no test checks what happens after the error.
    # `statement_removal` never touches the last statement of a list, so
    # without this operator a one-statement `rescue` body gets no mutant.
    #
    # A re-raise or a `retry` body is mutated too: `nil` swallows the error,
    # which a test that expects the error kills. An empty body and a body
    # that is already `nil` give no mutant, because the edit would change
    # nothing. An `ensure` body is not a rescue body.
    class RescueBody < Base
      # Visits rescue clauses and emits a body removal.
      #
      # @param node [Prism::RescueNode] rescue clause to inspect.
      # @return [void]
      def visit_rescue_node(node)
        emit(node.statements)
        super # the next clause and nested rescues each get their own mutation
      end

      # Visits rescue modifiers and emits a value removal.
      #
      # @param node [Prism::RescueModifierNode] rescue modifier to inspect.
      # @return [void]
      def visit_rescue_modifier_node(node)
        emit(node.rescue_expression)
        super
      end

      private

      # Emits a mutation that replaces the node with `nil`.
      #
      # @param node [Prism::Node, nil] rescue body or rescue-modifier value.
      # @return [void]
      def emit(node)
        return if node.nil? || node.is_a?(Prism::NilNode)
        return if node.is_a?(Prism::StatementsNode) && node.body.size == 1 && node.body.first.is_a?(Prism::NilNode)

        @mutations << Mutation.new(
          start_offset: node.location.start_offset,
          end_offset: node.location.end_offset,
          replacement: "nil",
          operator: :rescue_body
        )
      end
    end
  end
end
