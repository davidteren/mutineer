# frozen_string_literal: true

require "prism"
require_relative "../mutation"

module Mutineer
  # Namespace for all built-in mutator implementations.
  module Mutators
    # Base Prism visitor for operators.
    #
    # Subclasses override `visit_*` methods to push `Mutation` objects onto
    # `@mutations`. Visiting only `def_node.body` is the body-only enforcement:
    # the def signature line is never touched.
    #
    # ponytail: one implementor in M1; Base earns its keep at M4 when
    # comparison/boolean operators land and share this contract.
    class Base < Prism::Visitor
      # Walks the subject body and collects mutations.
      #
      # @param subject [Mutineer::Subject] subject whose body is visited.
      # @param source [String] full source text for byte-based slicing.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @source = source
        @mutations = []
        subject.def_node.body&.accept(self)
        @mutations
      end

      private

      # Returns whether a node is, or contains, a heredoc.
      #
      # A heredoc's body lies outside its node's byte range. A mutation that
      # deletes the node leaves the body behind as code, so the mutant
      # always raises.
      #
      # @param node [Prism::Node] node to inspect.
      # @return [Boolean] true when a heredoc is inside the node.
      def heredoc?(node)
        (node.respond_to?(:heredoc?) && node.heredoc?) ||
          node.compact_child_nodes.any? { |child| heredoc?(child) }
      end
    end
  end
end
