# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Return-nil mutator.
    #
    # Replaces explicit return values and final expressions with nil.
    class ReturnNil < Base
      # Collects return-nil mutations for a subject.
      #
      # @param subject [Mutineer::Subject] subject to inspect.
      # @param source [String] full source text.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @source = source
        @mutations = []
        @declined = 0
        @body = subject.def_node.body
        if @body
          @body.accept(self)       # rule 1 (explicit return nodes in this body)
          final_expression_nil(@body) # rule 2 (method's final expression)
        end
        drop_dangling_heredocs
        @mutations
      end

      # Visits return nodes.
      #
      # @param node [Prism::ReturnNode] node to inspect.
      # @return [void]
      def visit_return_node(node)
        args = node.arguments
        if args
          values = args.arguments
          unless values.size == 1 && values.first.is_a?(Prism::NilNode)
            emit(args.location)
          end
        end
        super
      end

      private

      # Mutates a method's final expression to nil when eligible.
      #
      # A def-level `rescue`, `else` or `ensure` makes the body a `BeginNode`
      # (#418). The method then returns the `else` value, or the main body's
      # value when there is no `else`, or the value of the `rescue` clause that
      # ran. Each of those final expressions becomes nil. The `ensure` value is
      # discarded, so it is not a final expression.
      #
      # @param body [Prism::Node, nil] method body node, or a statement list in it.
      # @return [void]
      def final_expression_nil(body)
        case body
        when Prism::StatementsNode
          last = body.body.last
          return if last.nil? || last.is_a?(Prism::ReturnNode) || last.is_a?(Prism::NilNode)

          emit(last.location)
        when Prism::BeginNode
          final_expression_nil(body.else_clause ? body.else_clause.statements : body.statements)
          clause = body.rescue_clause
          while clause
            final_expression_nil(clause.statements)
            clause = clause.subsequent # Prism 2 removed the `consequent` alias.
          end
        end
      end

      # Emits a return-nil mutation.
      #
      # @param loc [Prism::Location] source location.
      # @return [void]
      def emit(loc)
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: "nil",
          operator: :return_nil
        )
      end
    end
  end
end
