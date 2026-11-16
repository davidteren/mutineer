# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Literal mutation mutator.
    #
    # Mutates integers and strings with the Tier-2 literal rules.
    class LiteralMutation < Base
      # Resets the per-subject record of `"..."` string parts.
      #
      # @param subject [Mutineer::Subject] subject whose body is visited.
      # @param source [String] full source text for byte-based slicing.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @double_quoted_parts = {}.compare_by_identity
        super
      end

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

      # Records the text parts of a `"..."` interpolated string. In those,
      # `""` closes and reopens the string, so it empties the part.
      #
      # @param node [Prism::InterpolatedStringNode] node to inspect.
      # @return [void]
      def visit_interpolated_string_node(node)
        node.parts.each { |part| @double_quoted_parts[part] = true } if node.opening_loc&.slice == '"'
        super
      end

      # Visits string literals. A string with no quotes of its own (a heredoc
      # line, a `%(...)` or `%Q(...)` part, a `%w[]` element, a regex or
      # backtick part) cannot be emptied with `""`: the edit inserts text and
      # can break the parse (#469). Such a string is declined.
      #
      # @param node [Prism::StringNode] node to inspect.
      # @return [void]
      def visit_string_node(node)
        loc = node.location
        token = @source.byteslice(loc.start_offset...loc.end_offset)
        unless token == '""' || token == "''" || node.unescaped.empty?
          quoted = node.opening_loc || @double_quoted_parts.delete(node)
          quoted ? emit(loc, '""') : decline
        end
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
