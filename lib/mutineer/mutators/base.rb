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

      # Skips a nested method definition. The project finds it as a subject of
      # its own, so a visit here counts its mutations twice. Inside
      # `class << obj`, the project finds no subject, so the visit continues.
      #
      # @param node [Prism::DefNode] nested definition node.
      # @return [void]
      def visit_def_node(node)
        super if @in_undiscovered
      end

      # Tracks a `class << obj` whose `obj` is not `self`. The project does not
      # recurse into it, so its defs are no subjects (see
      # `Project::SubjectVisitor#visit_singleton_class_node`).
      #
      # @param node [Prism::SingletonClassNode] singleton-class node.
      # @return [void]
      def visit_singleton_class_node(node)
        return super if node.expression.is_a?(Prism::SelfNode)

        outer, @in_undiscovered = @in_undiscovered, true
        super
        @in_undiscovered = outer
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
