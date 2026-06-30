# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Statement-removal mutator.
    #
    # Replaces each non-final method statement with `nil`.
    class StatementRemoval < Base
      # Visits statement nodes and emits removals.
      #
      # @param node [Prism::StatementsNode] statement list to inspect.
      # @return [void]
      def visit_statements_node(node)
        stmts = node.body
        return if stmts.length < 2

        stmts[0...-1].each do |stmt|
          loc = stmt.location
          @mutations << Mutation.new(
            start_offset: loc.start_offset,
            end_offset: loc.end_offset,
            replacement: "nil",
            operator: :statement_removal
          )
        end
      end
    end
  end
end
