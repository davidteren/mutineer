# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Range mutator (Tier-2).
    #
    # Swaps `..` with `...` and `...` with `..`, one mutation per range. The
    # `..` -> `...` mutant survives when no test checks the last element.
    # Flip-flops are FlipFlopNode, not RangeNode, so this mutator skips them.
    #
    # An endless range (`1..`, `1..nil`) is skipped only when it is a direct
    # argument of a call in {SLICE_CALLS} or of an index write (`a[1..] += x`).
    # There `(1..)` and `(1...)` select the same elements, so the mutant is
    # equivalent. Every other endless range is swapped, because the two ranges
    # differ on `==`, `hash`, `exclude_end?` and `to_s`, so a test can kill it.
    class RangeLiteral < Base
      # Maps each range operator to its opposite.
      SWAPS = { ".." => "...", "..." => ".." }.freeze

      # Calls whose direct endless-range arguments are not mutated. They select
      # the same elements for `(1..)` and `(1...)`. The check uses the name only.
      SLICE_CALLS = %i[[] []= slice slice! byteslice bytesplice values_at].freeze

      # Resets the per-subject record of endless ranges that are slice arguments.
      #
      # @param subject [Mutineer::Subject] subject whose body is visited.
      # @param source [String] full source text for byte-based slicing.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @slice_args = {}.compare_by_identity
        super
      end

      # Visits a call. Records the range arguments of a call in {SLICE_CALLS}.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        record_slice_args(node) if SLICE_CALLS.include?(node.name)
        super
      end

      # Visits `a[1..] += x`. Its index arguments are slice arguments.
      #
      # @param node [Prism::IndexOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_index_operator_write_node(node)
        record_slice_args(node)
        super
      end

      # Visits `a[1..] ||= x`. Its index arguments are slice arguments.
      #
      # @param node [Prism::IndexOrWriteNode] node to inspect.
      # @return [void]
      def visit_index_or_write_node(node)
        record_slice_args(node)
        super
      end

      # Visits `a[1..] &&= x`. Its index arguments are slice arguments.
      #
      # @param node [Prism::IndexAndWriteNode] node to inspect.
      # @return [void]
      def visit_index_and_write_node(node)
        record_slice_args(node)
        super
      end

      # Visits an index used as an assignment target, as in `a[1..], b = x, y`.
      # Its index arguments are slice arguments.
      #
      # @param node [Prism::IndexTargetNode] node to inspect.
      # @return [void]
      def visit_index_target_node(node)
        record_slice_args(node)
        super
      end

      # Visits range nodes and emits range mutations.
      #
      # @param node [Prism::RangeNode] range node to inspect.
      # @return [void]
      def visit_range_node(node)
        emit(node) unless endless?(node) && @slice_args.key?(node)
        super # nested ranges ((1..2)...(3..4)) each get their own mutation
      end

      private

      # Records each range that is a direct argument of the node. For a `[]=`
      # call the last argument is the assigned value, not an index, so it is
      # left out.
      #
      # @param node [Prism::Node] call or index node that responds to `arguments`.
      # @return [void]
      def record_slice_args(node)
        args = node.arguments&.arguments || []
        args = args[0...-1] if node.is_a?(Prism::CallNode) && node.name == :[]=
        args.each { |arg| @slice_args[arg] = true if arg.is_a?(Prism::RangeNode) }
      end

      # Whether the range has no end: `1..` or `1..nil`.
      #
      # @param node [Prism::RangeNode] range node to inspect.
      # @return [Boolean]
      def endless?(node)
        node.right.nil? || node.right.is_a?(Prism::NilNode)
      end

      # Emits the mutation that swaps the range operator.
      #
      # @param node [Prism::RangeNode] range node to mutate.
      # @return [void]
      def emit(node)
        loc = node.operator_loc
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: SWAPS.fetch(loc.slice),
          operator: :range
        )
      end
    end
  end
end
