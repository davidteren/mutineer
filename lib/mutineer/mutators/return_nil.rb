# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Return-value-nil operator (Tier 2, OFF by default). Two rules:
    #   1. an explicit `return <expr>` -> `return nil`, unless the value is
    #      already nil (no-op guard).
    #   2. a method body whose final expression is neither a ReturnNode nor a
    #      NilNode -> that expression becomes `nil`.
    # Nested defs are their own subjects, so we never descend into them (R10).
    #
    # Clean-room: from the spec's operator description, not the mutant gem.
    class ReturnNil < Base
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
      def visit_def_node(node); end

      private

      def final_expression_nil(body)
        return unless body.is_a?(Prism::StatementsNode)

        last = body.body.last
        return if last.nil? || last.is_a?(Prism::ReturnNode) || last.is_a?(Prism::NilNode)

        emit(last.location)
      end

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
