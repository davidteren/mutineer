# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # String literal mutator (Tier-2).
    #
    # Empties a non-empty string literal and fills an empty one. Only plain
    # quoted strings are touched; interpolated strings, heredocs and %-literals
    # are skipped for safety (they re-parse unpredictably).
    class StringLiteral < Base
      # Visits string literals.
      #
      # @param node [Prism::StringNode] node to inspect.
      # @return [void]
      def visit_string_node(node)
        # ponytail: only plain "..." / '...' quotes. opening is nil for
        # interpolation parts and %w[] elements; heredocs/%-literals use a
        # different opening token. Skipping them keeps mutants re-parseable.
        if %w[" '].include?(node.opening)
          loc = node.content_loc
          @mutations << Mutation.new(
            start_offset: loc.start_offset,
            end_offset: loc.end_offset,
            replacement: node.unescaped.empty? ? "mutineer" : "",
            operator: :string_literal
          )
        end
        super
      end
    end
  end
end
