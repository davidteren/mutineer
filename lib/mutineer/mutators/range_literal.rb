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
    # index argument of a call in {SLICE_CALLS} or of an index write
    # (`"ab"[1..] += x`) and the receiver is an array or string literal.
    # There `(1..)` and `(1...)` select the same elements, so the mutant is
    # equivalent, and each skipped range counts as declined. A variable, a
    # call, or a constant is swapped. The syntax does not record that
    # receiver's class, and a Hash, a Proc, or a custom `[]` can tell the two
    # ranges apart. Every other endless range is swapped, because the two
    # ranges differ on `==`, `hash`, `exclude_end?` and `to_s`, so a test can
    # kill it. This includes the value of `h[:k] = 1..` and a call on a class,
    # such as `Array[1..]`, which builds a value and does not slice.
    class RangeLiteral < Base
      # Maps each range operator to its opposite.
      SWAPS = { ".." => "...", "..." => ".." }.freeze

      # Calls whose direct endless-range index arguments are not mutated when
      # the receiver is an array or string literal. Those calls select the
      # same elements for `(1..)` and `(1...)`. The assigned value of `[]=`
      # is not an index, so it is mutated.
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

      # Visits a call. Records the range arguments of a call in {SLICE_CALLS}
      # when the receiver is an array or string literal.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        record_slice_args(node) if SLICE_CALLS.include?(node.name)
        super
      end

      # Visits `a[1..] += x`. Records its index arguments when the receiver is
      # an array or string literal.
      #
      # @param node [Prism::IndexOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_index_operator_write_node(node)
        record_slice_args(node)
        super
      end

      # Visits `a[1..] ||= x`. Records its index arguments when the receiver is
      # an array or string literal.
      #
      # @param node [Prism::IndexOrWriteNode] node to inspect.
      # @return [void]
      def visit_index_or_write_node(node)
        record_slice_args(node)
        super
      end

      # Visits `a[1..] &&= x`. Records its index arguments when the receiver is
      # an array or string literal.
      #
      # @param node [Prism::IndexAndWriteNode] node to inspect.
      # @return [void]
      def visit_index_and_write_node(node)
        record_slice_args(node)
        super
      end

      # Visits an index used as an assignment target, as in `a[1..], b = x, y`.
      # Records its index arguments when the receiver is an array or string literal.
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
        if endless?(node) && @slice_args.key?(node)
          decline
        else
          emit(node)
        end
        super # nested ranges ((1..2)...(3..4)) each get their own mutation
      end

      private

      # Records each range that is a direct argument of the node, when the
      # receiver is an array or string literal. For a `[]=` call the last
      # argument is the assigned value, not an index, so it is left out.
      # A variable, call, or constant is not recorded: its class is not fixed
      # by the syntax, so the range is swapped.
      #
      # @param node [Prism::Node] call or index node that responds to `arguments`.
      # @return [void]
      def record_slice_args(node)
        return unless sequence_receiver?(node.receiver)

        args = node.arguments&.arguments || []
        args = args[0...-1] if node.is_a?(Prism::CallNode) && node.name == :[]=
        args.each { |arg| @slice_args[arg] = true if arg.is_a?(Prism::RangeNode) }
      end

      # Whether the receiver's syntax is an Array or a String. A quoted string
      # or an array literal is. Parentheses are unwrapped to the value they
      # return, so `("ab")[1..]` is still a string. A `begin` counts only when
      # every branch that can supply its value is one of those literals: a
      # rescue or an else can return a Hash instead. Backticks are a call to
      # `` ` ``, which can be overridden, so they are not literals. A variable,
      # call, or constant is not either: it can hold a Hash, a Proc, or a
      # custom object, and an earlier assignment is not followed.
      #
      # @param node [Prism::Node, nil] receiver of a slice call or index write.
      # @return [Boolean]
      def sequence_receiver?(node)
        case node
        when Prism::ArrayNode, Prism::StringNode, Prism::InterpolatedStringNode
          true
        when Prism::ParenthesesNode
          sequence_receiver?(statement_value(node.body))
        when Prism::BeginNode
          begin_is_sequence?(node)
        else
          false
        end
      end

      # Whether every value a `begin` can return is an array or string literal.
      # The value is the else, or the body when there is no else. Each rescue
      # can replace it. `ensure` runs but does not supply the value.
      #
      # @param node [Prism::BeginNode] begin expression used as a receiver.
      # @return [Boolean]
      def begin_is_sequence?(node)
        success = if node.else_clause
                    statement_value(node.else_clause.statements)
                  else
                    statement_value(node.statements)
                  end
        return false unless sequence_receiver?(success)

        rescue_clause = node.rescue_clause
        while rescue_clause
          return false unless sequence_receiver?(statement_value(rescue_clause.statements))

          rescue_clause = rescue_clause.subsequent
        end
        true
      end

      # The value of a statement list, which is its last statement. Any other
      # node is itself.
      #
      # @param node [Prism::Node, nil] statements, or a single expression.
      # @return [Prism::Node, nil]
      def statement_value(node)
        node.is_a?(Prism::StatementsNode) ? node.body.last : node
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
