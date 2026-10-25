# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Call-to-receiver mutator (Tier-2).
    #
    # Replaces the last call of a chain with its receiver, with the arguments
    # and the block of that call: `user.full_name` becomes `user`, and
    # `ids.uniq.sort` becomes `ids.uniq`. A chain begins at a receiver that is
    # not a dotted call, as in {ChainLink}. A call in an argument or a block
    # starts a chain of its own.
    #
    # The mutant survives when no test checks what the last call does: a strip,
    # a uniq, a compact or a lookup the tests never see.
    #
    # The operator does not overlap with {ChainLink}. `chain_link` drops a link
    # in the middle of a chain, and this operator drops the last call. A call
    # that is the receiver of a dotted call, or of a call write or a call
    # target, is a link, so it gets no mutant here. The two operators give the
    # same source only when the last call repeats the link before it, as in
    # `node.name.name`.
    #
    # Calls in {SKIPPED} are never replaced. The list is shorter than
    # {ChainLink::SKIPPED}: on the last call, a conversion such as `to_s` or
    # `to_i` decides the type of the value that the expression returns, so
    # `m[1].to_i` becomes `m[1]`. `Foo.new` becomes the class, and almost any
    # use of the class raises.
    #
    # A call is not replaced when its name is an operator (`a.+(1)`), or a
    # setter (`a.b = 1`). A call with no dot (`a + b`, `a[0]`) is not replaced.
    class CallToReceiver < Base
      # Matches the name of a call written as a word, not as an operator.
      WORD_NAME = /\A[[:alpha:]_]/

      # Method names whose last call is never replaced. A name is here when
      # its mutant is most often equivalent, or when almost any test that runs
      # the line kills it. `freeze` and `itself` return the receiver. `dup`
      # and `clone` return a copy, so the mutant shows when code later changes
      # the copy or the original, or compares the result with the original by
      # identity. Dropping `to_set` most often leaves an Array, which answers
      # `include?` and `empty?` as a Set does (it keeps duplicates, so `size`
      # and `each` can differ). `new` leaves the class in place of an
      # instance, which almost any test that runs the line kills.
      SKIPPED = %i[new dup clone freeze itself to_set].freeze

      # Resets the per-subject record of calls that are links.
      #
      # @param subject [Mutineer::Subject] subject whose body is visited.
      # @param source [String] full source text for byte-based slicing.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @links = {}.compare_by_identity
        super
      end

      # Visits a call. A dotted call that is not a link is the last call of its
      # chain.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        mark(node)
        replace(node) if dotted?(node) && !@links.key?(node)
        super
      end

      # Visits `a.b.c += 1`. Its receiver is a link.
      #
      # @param node [Prism::CallOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_call_operator_write_node(node)
        mark(node)
        super
      end

      # Visits `a.b.c ||= 1`. Its receiver is a link.
      #
      # @param node [Prism::CallOrWriteNode] node to inspect.
      # @return [void]
      def visit_call_or_write_node(node)
        mark(node)
        super
      end

      # Visits `a.b.c &&= 1`. Its receiver is a link.
      #
      # @param node [Prism::CallAndWriteNode] node to inspect.
      # @return [void]
      def visit_call_and_write_node(node)
        mark(node)
        super
      end

      # Visits a call used as an assignment target, as in `a.b.c, d = 1, 2`.
      # Its receiver is a link.
      #
      # @param node [Prism::CallTargetNode] node to inspect.
      # @return [void]
      def visit_call_target_node(node)
        mark(node)
        super
      end

      private

      # Records the receiver of a node as a link when the node is a dotted call
      # or a call write or target. The receiver of a call with no dot is not a
      # link. It is the last call of a chain of its own.
      #
      # @param node [Prism::Node] node that responds to `receiver`.
      # @return [void]
      def mark(node)
        @links[node.receiver] = true if dotted?(node) || !node.is_a?(Prism::CallNode)
      end

      # Emits the replacement of a call by its receiver, unless the name is an
      # operator, a setter, or in {SKIPPED}.
      #
      # @param node [Prism::CallNode] the dotted call to replace.
      # @return [void]
      def replace(node)
        name = node.name.to_s
        return unless name.match?(WORD_NAME)
        return if name.end_with?("=")
        return if SKIPPED.include?(node.name)

        receiver = node.receiver.location
        @mutations << Mutation.new(
          start_offset: node.location.start_offset,
          end_offset: node.location.end_offset,
          replacement: @source.byteslice(receiver.start_offset, receiver.end_offset - receiver.start_offset),
          operator: :call_to_receiver
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
