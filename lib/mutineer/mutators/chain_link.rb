# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Chain-link mutator (Tier-2).
    #
    # Drops one dotted call from a chain of calls, with its arguments and block:
    # `user.account.owner.name` becomes `user.owner.name` and `user.account.name`.
    # The chain's receiver and its final call stay, so a chain of n dotted calls
    # gives at most n - 1 mutations. A chain begins at a receiver that is not a
    # dotted call: a local, a constant, `self`, `list[i]`, `(a + b)`. A call in
    # an argument or a block starts a chain of its own.
    #
    # The mutant survives when no test tells the chain apart from the same chain
    # without that step: a scope, a filter or a lookup the tests never see.
    #
    # Links in {SKIPPED} are never dropped. On a value that already has the
    # target type or needs no copy, a conversion (`name.to_s.strip`) or a copy
    # (`list.dup.sort`) is a no-op, so dropping it most often makes an
    # equivalent mutant. Dropping `new` sends the next call to the class, which
    # raises (killed by any test that runs the line) or reaches a class method
    # that builds the instance itself (equivalent); neither says anything about
    # the tests.
    class ChainLink < Base
      # Method names whose link is never dropped: core conversions and copies,
      # plus `new`.
      SKIPPED = %i[
        to_s to_str to_sym to_i to_int to_f to_r to_c to_a to_ary to_h to_hash to_proc to_set
        dup clone freeze itself
        new
      ].freeze

      # Resets the per-subject record of calls already placed in a chain.
      #
      # @param subject [Mutineer::Subject] subject whose body is visited.
      # @param source [String] full source text for byte-based slicing.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @links = {}.compare_by_identity
        super
      end

      # Visits a call. The outermost dotted call of a chain is its final call;
      # the dotted calls below it in the receiver are its links.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        chain(node) if dotted?(node) && !@links.key?(node)
        super
      end

      # Visits `a.b.c += 1`, whose final call Prism parses as its own node.
      #
      # @param node [Prism::CallOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_call_operator_write_node(node)
        chain(node)
        super
      end

      # Visits `a.b.c ||= 1`.
      #
      # @param node [Prism::CallOrWriteNode] node to inspect.
      # @return [void]
      def visit_call_or_write_node(node)
        chain(node)
        super
      end

      # Visits `a.b.c &&= 1`.
      #
      # @param node [Prism::CallAndWriteNode] node to inspect.
      # @return [void]
      def visit_call_and_write_node(node)
        chain(node)
        super
      end

      # Visits a call used as an assignment target, as in `a.b.c, d = 1, 2`.
      #
      # @param node [Prism::CallTargetNode] node to inspect.
      # @return [void]
      def visit_call_target_node(node)
        chain(node)
        super
      end

      # Nested method definitions are discovered as their own subjects; do not
      # recurse into them (prevents double-counting their chains).
      #
      # @param node [Prism::DefNode] nested definition node.
      # @return [void]
      def visit_def_node(node); end

      private

      # Walks a final call's receiver chain, recording each link so it is not
      # taken for the final call of a chain of its own, and dropping each link
      # not in {SKIPPED}.
      #
      # @param top [Prism::Node] the chain's final call; responds to `receiver`.
      # @return [void]
      def chain(top)
        link = top.receiver
        while dotted?(link)
          @links[link] = true
          drop(link) unless SKIPPED.include?(link.name)
          link = link.receiver
        end
      end

      # Emits the removal of one link: from the end of its receiver to the end
      # of its arguments and block, so a chain split across lines keeps the
      # layout of the lines that remain.
      #
      # @param link [Prism::CallNode] the dotted call to drop.
      # @return [void]
      def drop(link)
        @mutations << Mutation.new(
          start_offset: link.receiver.location.end_offset,
          end_offset: link.location.end_offset,
          replacement: "",
          operator: :chain_link
        )
      end

      # Returns whether a node is a call through `.`, `&.` or `::`.
      #
      # @param node [Prism::Node, nil] node to inspect.
      # @return [Boolean] true for a call node with a call operator.
      def dotted?(node)
        node.is_a?(Prism::CallNode) && !node.call_operator_loc.nil?
      end
    end
  end
end
