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
    class Base < Prism::Visitor
      # Walks the subject body and collects mutations.
      #
      # @param subject [Mutineer::Subject] subject whose body is visited.
      # @param source [String] full source text for byte-based slicing.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @source = source
        @mutations = []
        @declined = 0
        @body = subject.def_node.body
        @body&.accept(self)
        drop_dangling_heredocs
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

      # Returns how many candidates the last {#mutations_for} call declined: an
      # edit that would split a heredoc from its body, or an equivalent skip
      # listed in docs/equivalent-skips.md. A declined candidate is never a
      # mutation, so it is not in the run's total.
      #
      # @return [Integer] declined candidates; 0 before the first call.
      def declined
        @declined || 0
      end

      private

      # Counts one declined candidate.
      #
      # @return [nil] so a skip line reads `return decline if ...`.
      def decline
        @declined += 1
        nil
      end

      # Drops a mutation that splits a heredoc opener from its body.
      #
      # The body sits past the opener's node. Replacing the opener with text
      # that does not contain it turns the body into Ruby, which parses and
      # then raises. A replacement that still contains the opener keeps the
      # body attached, so that mutation stays. The reverse also breaks: when
      # the replaced range holds the body but the replacement keeps only the
      # opener, the opener has no body and the source does not parse. A
      # replacement that copies the opener and the body together stays.
      # Each dropped mutation counts as declined.
      #
      # @return [void]
      def drop_dangling_heredocs
        before = @mutations.size
        @mutations.reject! { |mutation| dangling_heredoc?(mutation) }
        @declined += before - @mutations.size
      end

      # Returns whether the mutation replaces a heredoc opener and keeps the
      # opener without its body, or the body without its opener.
      #
      # @param mutation [Mutineer::Mutation] candidate edit.
      # @param node [Prism::Node, nil] subtree to search. Defaults to the body.
      # @return [Boolean] true when the edit would split a heredoc from its body.
      def dangling_heredoc?(mutation, node = @body)
        return false if node.nil? || !node.is_a?(Prism::Node)

        if node.respond_to?(:heredoc?) && node.heredoc? && node.respond_to?(:opening_loc)
          opening = node.opening_loc
          if opening && opening.start_offset >= mutation.start_offset && opening.start_offset < mutation.end_offset
            closing = node.respond_to?(:closing_loc) ? node.closing_loc : nil
            hangs = closing.nil? || closing.end_offset > mutation.end_offset
            opener = @source.byteslice(opening.start_offset, opening.end_offset - opening.start_offset)
            kept = !opener.empty? && mutation.replacement.include?(opener)
            if hangs
              return true unless kept
            elsif kept
              whole = @source.byteslice(opening.start_offset, closing.end_offset - opening.start_offset)
              return true unless mutation.replacement.include?(whole)
            end
          end
        end

        node.compact_child_nodes.any? { |child| dangling_heredoc?(mutation, child) }
      end

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
