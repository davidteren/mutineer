# frozen_string_literal: true

require "prism"
require_relative "../mutation"

module Brutus
  module Mutators
    # Base Prism visitor for operators. Subclasses override visit_* methods to
    # push Mutation objects onto @mutations. Visiting only def_node.body is the
    # body-only enforcement — the def signature line is never touched.
    #
    # ponytail: one implementor in M1; Base earns its keep at M4 when
    # comparison/boolean operators land and share this contract.
    class Base < Prism::Visitor
      def mutations_for(subject, source)
        @source = source
        @mutations = []
        subject.def_node.body&.accept(self)
        @mutations
      end
    end
  end
end
