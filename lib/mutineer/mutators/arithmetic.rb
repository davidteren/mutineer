# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Arithmetic operator: +<->-, *<->/, %->*, **->*. One mutation per
    # occurrence, rewriting the operator token (CallNode#message_loc).
    class Arithmetic < Base
      REPLACEMENTS = {
        :+ => "-", :- => "+", :* => "/", :/ => "*", :% => "*", :** => "*"
      }.freeze

      def visit_call_node(node)
        replacement = REPLACEMENTS[node.name]
        loc = node.message_loc
        if replacement && loc
          @mutations << Mutation.new(
            start_offset: loc.start_offset,
            end_offset: loc.end_offset,
            replacement: replacement,
            operator: :arithmetic
          )
        end
        super # nested calls (e.g. a + (b * c)) each get their own mutation
      end
    end
  end
end
