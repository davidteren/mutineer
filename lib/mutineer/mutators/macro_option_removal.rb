# frozen_string_literal: true

require_relative "macro_base"

module Mutineer
  module Mutators
    # Replaces one keyword pair on a class-body macro call with `**{}`.
    #
    # The replacement starts at the pair, so the mutant stays on the pair's
    # line. The preceding comma stays. An empty double splat passes no keyword.
    class MacroOptionRemoval < MacroBase
      # Keys Rails treats as conditions, not validators.
      #
      # Removing the last validator from `validates` raises when the file
      # loads. `except_on` is included for the Rails 8 list as well as the
      # Rails 7 list. `validates_with` takes a positional validator, so it
      # never uses this list.
      NON_VALIDATOR_KEYS = %i[if unless on allow_blank allow_nil strict except_on].freeze

      # Replaces each keyword pair on the subject call.
      #
      # @param node [Prism::CallNode] call to inspect.
      # @return [void]
      def visit_call_node(node)
        return unless node.equal?(@body)

        keywords = keyword_hash(node)
        return unless keywords

        pairs = keywords.elements.select { |element| element.is_a?(Prism::AssocNode) }
        pairs.each do |pair|
          next decline if leaves_no_validator?(node, pairs, pair)

          loc = pair.location
          @mutations << Mutation.new(
            start_offset: loc.start_offset,
            end_offset: loc.end_offset,
            replacement: "**{}",
            operator: :macro_option_removal
          )
        end
      end

      private

      # The last keyword-argument list on the call, if it has one.
      #
      # @param node [Prism::CallNode] macro call.
      # @return [Prism::KeywordHashNode, nil]
      def keyword_hash(node)
        arguments = node.arguments&.arguments || []
        arguments.reverse.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
      end

      # True when removing this pair from `validates` leaves no validator key.
      #
      # @param node [Prism::CallNode] macro call.
      # @param pairs [Array<Prism::AssocNode>] keyword pairs on the call.
      # @param pair [Prism::AssocNode] pair being removed.
      # @return [Boolean]
      def leaves_no_validator?(node, pairs, pair)
        return false unless node.name == :validates

        (pairs - [pair]).none? { |other| validator_key?(other) }
      end

      # True when the pair's key is a validator, or is not a literal symbol.
      #
      # @param pair [Prism::AssocNode] keyword pair.
      # @return [Boolean]
      def validator_key?(pair)
        key = pair.key
        return true unless key.is_a?(Prism::SymbolNode)

        !NON_VALIDATOR_KEYS.include?(key.value.to_sym)
      end
    end
  end
end
