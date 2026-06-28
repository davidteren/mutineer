# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Statement-removal operator: replace each non-final method statement with
    # "nil". Tests whether the suite detects a missing side effect. The final
    # expression is always skipped — replacing the return value with nil is the
    # M5 return-nil operator's distinct concern (KTD-1). A body with < 2
    # statements has no non-final statement, so it generates nothing.
    #
    # Clean-room: from the spec's operator description, not the mutant gem.
    class StatementRemoval < Base
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
        # ponytail: no super — recursing into a nested StatementsNode would
        # re-emit removals already covered at the top level and double-count.
        # Each subject's body is visited once.
      end
    end
  end
end
