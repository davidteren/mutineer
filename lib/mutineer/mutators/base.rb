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
        @body = subject.def_node.body
        @body&.accept(self)
        drop_dangling_heredocs
        drop_repeated_results
        @mutations
      end

      private

      # Keeps only the first mutation for each mutated source (#159). Two rules
      # can give one edit: `0` changed to 1 and `0` plus 1, or either `!` of
      # `!!x` removed. Each copy got its own id, so one surviving edit counted
      # twice. Every mutation leaves the source outside the span from the
      # earliest start to the latest end alone, so comparing that span is exact
      # and cheaper than comparing whole files.
      #
      # @return [void]
      def drop_repeated_results
        return if @mutations.size < 2

        from = @mutations.map(&:start_offset).min
        to = @mutations.map(&:end_offset).max
        @mutations.uniq! do |m|
          "#{@source.byteslice(from...m.start_offset)}#{m.replacement}#{@source.byteslice(m.end_offset...to)}"
        end
      end

      # Drops a mutation that deletes a heredoc opener and leaves its body.
      #
      # The body sits past the opener's node. Replacing the opener with text
      # that does not contain it turns the body into Ruby, which parses and
      # then raises. A replacement that still contains the opener keeps the
      # body attached, so that mutation stays.
      #
      # @return [void]
      def drop_dangling_heredocs
        @mutations.reject! { |mutation| dangling_heredoc?(mutation) }
      end

      # Returns whether the mutation removes a heredoc opener whose body hangs
      # past the replaced range.
      #
      # @param mutation [Mutineer::Mutation] candidate edit.
      # @param node [Prism::Node, nil] subtree to search. Defaults to the body.
      # @return [Boolean] true when the edit would leave a heredoc body behind.
      def dangling_heredoc?(mutation, node = @body)
        return false if node.nil? || !node.is_a?(Prism::Node)

        if node.respond_to?(:heredoc?) && node.heredoc? && node.respond_to?(:opening_loc)
          opening = node.opening_loc
          if opening && opening.start_offset >= mutation.start_offset && opening.start_offset < mutation.end_offset
            closing = node.respond_to?(:closing_loc) ? node.closing_loc : nil
            hangs = closing.nil? || closing.end_offset > mutation.end_offset
            if hangs
              opener = @source.byteslice(opening.start_offset, opening.end_offset - opening.start_offset)
              return true if opener.empty? || !mutation.replacement.include?(opener)
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
