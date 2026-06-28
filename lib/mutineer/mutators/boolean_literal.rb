# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Mutates true/false AND nil literals — "boolean_literal" is the spec's name
    # for the family (§4), so nil is in-scope by design even though it is not
    # strictly a boolean. true<->false, and nil->true (nil->true catches more
    # return-value gaps than nil->false). Rewrites the whole node location;
    # these nodes have no sub-token location.
    #
    # Clean-room: from the spec's operator table, not the mutant gem.
    class BooleanLiteral < Base
      def visit_true_node(node)
        emit(node, "false")
        super
      end

      def visit_false_node(node)
        emit(node, "true")
        super
      end

      def visit_nil_node(node)
        emit(node, "true")
        super
      end

      private

      def emit(node, replacement)
        loc = node.location
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: replacement,
          operator: :boolean_literal
        )
      end
    end
  end
end
