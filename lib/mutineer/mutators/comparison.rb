# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Comparison and boundary mutator.
    #
    # Rewrites comparison operators one occurrence at a time.
    class Comparison < Base
      # Token replacements for comparison operators.
      REPLACEMENTS = {
        :< => "<=", :<= => "<", :> => ">=", :>= => ">", :== => "!=", :!= => "=="
      }.freeze

      # Visits call nodes and emits comparison mutations.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        replacement = REPLACEMENTS[node.name]
        loc = node.message_loc
        if replacement && loc && node.receiver
          @mutations << Mutation.new(
            start_offset: loc.start_offset,
            end_offset: loc.end_offset,
            replacement: replacement,
            operator: :comparison
          )
        end
        super # nested comparisons (a >= b && c <= d) each get their own mutation
      end
    end
  end
end
