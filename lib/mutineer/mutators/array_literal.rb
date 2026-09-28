# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Array-literal mutator (Tier-2).
    #
    # Replaces a non-empty array literal with an empty one, one mutation per
    # literal: `[a, b]` and `%i[a b]` become `[]`. The mutant survives when no
    # test checks the contents of the array.
    class ArrayLiteral < Base
      # Visits array nodes and emits array-literal mutations.
      #
      # @param node [Prism::ArrayNode] array node to inspect.
      # @return [void]
      def visit_array_node(node)
        emit(node)
        super # nested arrays each get their own mutation
      end

      # Skips a nested method definition. The project finds it as a subject of
      # its own, so a visit here counts its arrays twice.
      #
      # @param node [Prism::DefNode] nested definition node.
      # @return [void]
      def visit_def_node(node); end

      private

      # Emits a mutation for a non-empty array with brackets.
      #
      # The operator skips an implicit array (`x = 1, 2`), because it has no
      # brackets. It also skips an array that holds a heredoc, because the
      # heredoc body stays behind as code.
      #
      # @param node [Prism::ArrayNode] array node to inspect.
      # @return [void]
      def emit(node)
        return if node.opening_loc.nil? || node.elements.empty? || heredoc?(node)

        @mutations << Mutation.new(
          start_offset: node.location.start_offset,
          end_offset: node.location.end_offset,
          replacement: "[]",
          operator: :array_literal
        )
      end
    end
  end
end
