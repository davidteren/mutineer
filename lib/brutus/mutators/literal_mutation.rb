# frozen_string_literal: true

require_relative "base"

module Brutus
  module Mutators
    # Literal-fuzzing operator (Tier 2, OFF by default). Integers emit up to
    # three mutations (0, 1, n+1) with no-op guards for 0 and 1; strings collapse
    # to "" unless already empty. One mutation per emitted candidate (R11).
    #
    # Clean-room: from the spec's operator description, not the mutant gem.
    class LiteralMutation < Base
      def visit_integer_node(node)
        n = node.value
        emit(node.location, "0") unless n.zero?
        emit(node.location, "1") unless n == 1
        emit(node.location, (n + 1).to_s)
        super
      end

      def visit_string_node(node)
        loc = node.location
        token = @source[loc.start_offset...loc.end_offset]
        emit(loc, '""') unless token == '""' || token == "''" || node.unescaped.empty?
        super
      end

      private

      def emit(loc, replacement)
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: replacement,
          operator: :literal_mutation
        )
      end
    end
  end
end
