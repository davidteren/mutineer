# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Literal mutation mutator.
    #
    # Mutates integers and strings with the Tier-2 literal rules.
    class LiteralMutation < Base
      # Visits integer literals.
      #
      # @param node [Prism::IntegerNode] node to inspect.
      # @return [void]
      def visit_integer_node(node)
        n = node.value
        emit(node.location, "0") unless n.zero?
        emit(node.location, "1") unless n == 1
        emit(node.location, (n + 1).to_s)
        super
      end

      # Visits string literals.
      #
      # @param node [Prism::StringNode] node to inspect.
      # @return [void]
      def visit_string_node(node)
        loc = node.location
        token = @source.byteslice(loc.start_offset...loc.end_offset)
        emit(loc, '""') unless token == '""' || token == "''" || node.unescaped.empty?
        super
      end

      private

      # Emits a literal mutation.
      #
      # @param loc [Prism::Location] source location.
      # @param replacement [String] replacement literal.
      # @return [void]
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
