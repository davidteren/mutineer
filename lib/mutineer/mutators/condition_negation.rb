# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Condition-negation operator (Tier 2, OFF by default). Wraps an if/unless/
    # ternary condition in `!( ... )` textually. Ruby ternaries parse as IfNode in
    # Prism, so visit_if_node covers them too (R12). The standard validity re-parse
    # downstream discards any wrap that fails to round-trip (R14).
    #
    # Clean-room: from the spec's operator description, not the mutant gem.
    class ConditionNegation < Base
      def visit_if_node(node)
        wrap(node.predicate)
        super
      end

      def visit_unless_node(node)
        wrap(node.predicate)
        super
      end

      private

      def wrap(predicate)
        return unless predicate

        loc = predicate.location
        original = @source.byteslice(loc.start_offset...loc.end_offset)
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: "!( #{original} )",
          operator: :condition_negation
        )
      end
    end
  end
end
