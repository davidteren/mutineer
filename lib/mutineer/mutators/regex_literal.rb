# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Regular-expression literal mutator (Tier-2).
    #
    # Conservative, clearly-safe textual swaps inside a plain regex literal:
    # drop a leading +^+ anchor, drop a trailing +$+ anchor, and swap the +
    # and * quantifiers. Interpolated regexes use a different node type and are
    # never visited. Escaped tokens (preceded by a backslash) are left alone.
    class RegexLiteral < Base
      # Visits regular-expression literals.
      #
      # @param node [Prism::RegularExpressionNode] node to inspect.
      # @return [void]
      def visit_regular_expression_node(node)
        loc = node.content_loc
        content = @source.byteslice(loc.start_offset...loc.end_offset)
        scan(content, loc.start_offset)
        super
      end

      private

      # Scans the pattern bytes and emits anchor/quantifier mutations.
      #
      # @param content [String] regex pattern between the slashes.
      # @param base [Integer] byte offset of the pattern start in source.
      # @return [void]
      def scan(content, base)
        emit(base, base + 1, "") if content.start_with?("^")
        emit(base + content.bytesize - 1, base + content.bytesize, "") if trailing_anchor?(content)

        escaped = false
        offset = base
        content.each_char do |ch|
          unless escaped
            emit(offset, offset + 1, "*") if ch == "+"
            emit(offset, offset + 1, "+") if ch == "*"
          end
          escaped = ch == "\\" && !escaped
          offset += ch.bytesize
        end
      end

      # Whether the pattern ends with an unescaped +$+ anchor.
      #
      # @param content [String] regex pattern.
      # @return [Boolean] true when a trailing anchor is droppable.
      def trailing_anchor?(content)
        content.end_with?("$") && !content.end_with?("\\$")
      end

      # Emits a regex mutation.
      #
      # @param start_offset [Integer] byte start.
      # @param end_offset [Integer] byte end.
      # @param replacement [String] replacement text.
      # @return [void]
      def emit(start_offset, end_offset, replacement)
        @mutations << Mutation.new(
          start_offset: start_offset,
          end_offset: end_offset,
          replacement: replacement,
          operator: :regex
        )
      end
    end
  end
end
