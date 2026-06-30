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
        body = subject.def_node.body
        if body
          body.accept(self)       # rule 1 (explicit return nodes in this body)
          final_expression_nil(body) # rule 2 (method's final expression)
        end
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

      # Nested method definitions are discovered as their own subjects; do not
      # recurse into them (prevents double-counting their statements).
      #
      # @param node [Prism::DefNode] nested definition node.
      # @return [void]
      def visit_def_node(node); end

      private

      # Mutates a method's final expression to nil when eligible.
      #
      # @param body [Prism::Node] method body node.
      # @return [void]
      def final_expression_nil(body)
        return unless body.is_a?(Prism::StatementsNode)

        last = body.body.last
        return if last.nil? || last.is_a?(Prism::ReturnNode) || last.is_a?(Prism::NilNode)

        emit(last.location)
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
