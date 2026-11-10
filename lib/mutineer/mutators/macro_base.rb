# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Shared walk for a class-body macro operator (#397).
    #
    # A method subject has no macro node, so it gets no mutations. The walk
    # starts at the macro call. {Base#decline} and {Base#drop_dangling_heredocs}
    # read the fields this method sets.
    class MacroBase < Base
      # Collects mutations of one macro call.
      #
      # @param subject [Mutineer::Subject] subject to inspect.
      # @param source [String] full source text.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @source = source
        @mutations = []
        @declined = 0
        return [] if subject.macro_node.nil?

        @body = subject.macro_node
        @body.accept(self)
        drop_dangling_heredocs
        @mutations
      end
    end
  end
end
