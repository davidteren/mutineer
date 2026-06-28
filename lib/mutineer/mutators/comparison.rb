# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Comparison / boundary operator: <->-<=, >->-=>, ==->!=, etc. The single
    # highest-value Tier-1 family (spec §4) — exposes off-by-one and boundary
    # gaps line coverage never catches. Rewrites the operator token
    # (CallNode#message_loc), one mutation per occurrence.
    #
    # Clean-room: implemented from the spec's operator table and public
    # mutation-testing literature, not the mutant gem.
    class Comparison < Base
      REPLACEMENTS = {
        :< => "<=", :<= => "<", :> => ">=", :>= => ">", :== => "!=", :!= => "=="
      }.freeze

      def visit_call_node(node)
        replacement = REPLACEMENTS[node.name]
        loc = node.message_loc
        # receiver guard: reject any unary call accidentally named like an
        # operator; binary comparisons always have a receiver.
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
