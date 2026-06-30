# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Collection / enumerable method-name mutator (Tier-2).
    #
    # Swaps the method-name token of a call to its semantic opposite, one
    # mutation per occurrence, exactly like the arithmetic/comparison operators.
    class CollectionMethod < Base
      # Method-name swaps. All targets are core-Ruby Enumerable/Array methods so
      # the mutant exercises real behaviour rather than always raising.
      #
      # ponytail: include? -> exclude? was specced but skipped — exclude? is not
      # core Ruby, so that mutant would always NoMethodError (a weak mutant).
      REPLACEMENTS = {
        map: "each", each: "map",
        all?: "any?", any?: "all?",
        first: "last", last: "first",
        min: "max", max: "min",
        select: "reject", reject: "select"
      }.freeze

      # Visits call nodes and emits collection-method mutations.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        replacement = REPLACEMENTS[node.name]
        loc = node.message_loc
        if replacement && loc
          @mutations << Mutation.new(
            start_offset: loc.start_offset,
            end_offset: loc.end_offset,
            replacement: replacement,
            operator: :collection_method
          )
        end
        super
      end
    end
  end
end
