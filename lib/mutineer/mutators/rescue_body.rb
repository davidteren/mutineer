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
    # that is already `nil`, `(nil)` or `()` give no mutant, because the edit
    # would change nothing. An `ensure` body is not a rescue body. On the
    # Fizzy copy (#418), 8 of 35 candidates give no mutant this way: 3 empty
    # bodies, 3 `nil` bodies and 2 `nil` modifier values.
    #
    # The operator declines a body whose value is discarded and that only
    # holds literals and variable reads (see docs/equivalent-skips.md).
    class RescueBody < Base
      # Statements that change no state and raise nothing, so dropping one
      # whose value is discarded changes nothing.
      INERT = [Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
               Prism::SymbolNode, Prism::StringNode, Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
               Prism::SelfNode, Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode].freeze

      # Collects rescue-body mutations for a subject.
      #
      # @param subject [Mutineer::Subject] subject to inspect.
      # @param source [String] full source text.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @discarded = {}.compare_by_identity
        @value_discarded = false
        super
      end

      # Marks every statement but the last as discarded: nothing reads its value.
      #
      # @param node [Prism::StatementsNode] statement list to inspect.
      # @return [void]
      def visit_statements_node(node)
        node.body[0...-1].each { |statement| @discarded[statement] = true }
        super
      end

      # Tracks whether this `begin` block's value, and so its rescue values, is discarded.
      #
      # @param node [Prism::BeginNode] begin block, or a def or block body with `rescue`.
      # @return [void]
      def visit_begin_node(node)
        outer = @value_discarded
        @value_discarded = @discarded.key?(node)
        super
      ensure
        @value_discarded = outer
      end

      # Visits rescue clauses and emits a body removal.
      #
      # @param node [Prism::RescueNode] rescue clause to inspect.
      # @return [void]
      def visit_rescue_node(node)
        emit(node.statements, @value_discarded)
        super # the next clause and nested rescues each get their own mutation
      end

      # Visits rescue modifiers and emits a value removal.
      #
      # @param node [Prism::RescueModifierNode] rescue modifier to inspect.
      # @return [void]
      def visit_rescue_modifier_node(node)
        emit(node.rescue_expression, @discarded.key?(node))
        super
      end

      private

      # Emits a mutation that replaces the node with `nil`.
      #
      # @param node [Prism::Node, nil] rescue body or rescue-modifier value.
      # @param discarded [Boolean] whether nothing reads the value.
      # @return [void]
      def emit(node, discarded)
        return if node.nil? || nil_value?(node)
        return decline if discarded && inert?(node)

        @mutations << Mutation.new(
          start_offset: node.location.start_offset,
          end_offset: node.location.end_offset,
          replacement: "nil",
          operator: :rescue_body
        )
      end

      # Returns whether the node is `nil`, alone or in parentheses, or `()`.
      #
      # @param node [Prism::Node] rescue body or rescue-modifier value.
      # @return [Boolean] true when replacing it with `nil` changes nothing.
      def nil_value?(node)
        case node
        when Prism::NilNode then true
        when Prism::StatementsNode then node.body.size == 1 && nil_value?(node.body.first)
        when Prism::ParenthesesNode then node.body.nil? || nil_value?(node.body)
        else false
        end
      end

      # Returns whether every statement in the node is a literal or a variable read.
      #
      # @param node [Prism::Node] rescue body or rescue-modifier value.
      # @return [Boolean] true when evaluating the node has no effect.
      def inert?(node)
        case node
        when Prism::StatementsNode then node.body.all? { |statement| inert?(statement) }
        when Prism::ParenthesesNode then node.body.nil? || inert?(node.body)
        else INERT.any? { |klass| node.is_a?(klass) }
        end
      end
    end
  end
end
