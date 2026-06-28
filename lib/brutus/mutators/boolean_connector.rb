# frozen_string_literal: true

require_relative "base"

module Brutus
  module Mutators
    # Boolean connector operator: && <-> ||, and <-> or. Replacement is derived
    # from the actual source token (operator_loc.slice) so symbolic and keyword
    # forms each map to their own form — never crossing && to `or`, which would
    # change precedence and surprise the reader (KTD-2).
    #
    # Clean-room: from the spec's operator table, not the mutant gem.
    class BooleanConnector < Base
      REPLACEMENTS = { "&&" => "||", "||" => "&&", "and" => "or", "or" => "and" }.freeze

      def visit_and_node(node)
        emit(node)
        super
      end

      def visit_or_node(node)
        emit(node)
        super
      end

      private

      def emit(node)
        loc = node.operator_loc
        replacement = REPLACEMENTS[loc.slice]
        return unless replacement

        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: replacement,
          operator: :boolean_connector
        )
      end
    end
  end
end
