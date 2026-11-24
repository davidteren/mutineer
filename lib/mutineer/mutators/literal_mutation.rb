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

      # Visits an interpolated string. In a `"..."` string, `""` over a text
      # part closes and reopens the string, so it empties the part. Any other
      # text part is handled as a string with no quotes of its own.
      #
      # @param node [Prism::InterpolatedStringNode] node to inspect.
      # @return [void]
      def visit_interpolated_string_node(node)
        double_quoted = node.opening_loc&.slice == '"'
        node.parts.each do |part|
          next part.accept(self) unless part.is_a?(Prism::StringNode)

          mutate_string(part, quoted: double_quoted || part.opening_loc)
        end
      end

      # Visits string literals.
      #
      # @param node [Prism::StringNode] node to inspect.
      # @return [void]
      def visit_string_node(node)
        mutate_string(node, quoted: node.opening_loc)
        super
      end

      private

      # Empties a non-empty string. A string with no quotes of its own (a
      # heredoc line, a `%(...)` or `%Q(...)` part, a `%w[]` element, a regex,
      # backtick or interpolated-symbol part) cannot be emptied with `""`: the edit inserts text
      # and can break the parse (#469). Such a string is declined.
      #
      # @param node [Prism::StringNode] string to inspect.
      # @param quoted [Object] truthy when `""` empties the string.
      # @return [void]
      def mutate_string(node, quoted:)
        return if node.unescaped.empty?
        return decline unless quoted

        loc = node.location
        token = @source.byteslice(loc.start_offset...loc.end_offset)
        emit(loc, '""') unless token == '""' || token == "''"
      end

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
