# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Collection / enumerable method-name mutator (Tier-2).
    #
    # Swaps the method-name token of a call to its semantic opposite, one
    # mutation per occurrence, exactly like the arithmetic/comparison operators.
    #
    # `each` and `map` are the exception. `each` returns its receiver and
    # `map` returns a new array. When that value is discarded, no test can
    # tell the mutant from the original, so the swap is declined. The other
    # swaps stay: `all?` and `any?` stop on different elements, so a block
    # can show the change even when the boolean is discarded.
    # See docs/equivalent-skips.md.
    class CollectionMethod < Base
      # Method-name swaps. All targets are core-Ruby Enumerable/Array methods so
      # the mutant exercises real behaviour rather than always raising.
      #
      # include? -> exclude? is left out: exclude? is not
      # core Ruby, so that mutant would always NoMethodError (a weak mutant).
      REPLACEMENTS = {
        map: "each", each: "map",
        all?: "any?", any?: "all?",
        first: "last", last: "first",
        min: "max", max: "min",
        select: "reject", reject: "select"
      }.freeze

      # Names whose swap changes the returned object and not the walk.
      # A discarded call is declined. The check is the syntax tree only:
      # it does not know the receiver's class.
      UNUSED_RESULT_NAMES = %i[each map].freeze

      # Parents that pass a child's value through. The child is observable
      # exactly when that parent is. An assignment, an argument, a receiver,
      # or an explicit `return` / `break` / `next` is not in this list: those
      # parents use the value even when their own result is discarded.
      VALUE_FLOWS = [
        Prism::ParenthesesNode,
        Prism::BeginNode,
        Prism::ElseNode,
        Prism::AndNode,
        Prism::OrNode,
        Prism::RescueModifierNode,
        Prism::ArrayNode,
        Prism::HashNode,
        Prism::KeywordHashNode,
        Prism::AssocNode,
        Prism::AssocSplatNode,
        Prism::SplatNode,
        Prism::RangeNode,
        Prism::InterpolatedStringNode,
        Prism::InterpolatedXStringNode,
        Prism::InterpolatedSymbolNode,
        Prism::InterpolatedRegularExpressionNode,
        Prism::EmbeddedStatementsNode
      ].freeze

      # Records parents, then walks the body. The result check needs the
      # parent of each call, and Prism nodes do not store one.
      #
      # @param subject [Mutineer::Subject] subject whose body is visited.
      # @param source [String] full source text for byte-based slicing.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @parents = {}.compare_by_identity
        index_parents(subject.def_node.body, nil)
        super
      end

      # Visits call nodes and emits collection-method mutations.
      # An {UNUSED_RESULT_NAMES} call whose value is discarded is declined.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        replacement = REPLACEMENTS[node.name]
        loc = node.message_loc
        if replacement && loc
          if unused_result?(node)
            decline
          else
            @mutations << Mutation.new(
              start_offset: loc.start_offset,
              end_offset: loc.end_offset,
              replacement: replacement,
              operator: :collection_method
            )
          end
        end
        super
      end

      private

      # Stores the parent of every node under `node`.
      #
      # @param node [Prism::Node, nil] subtree to index.
      # @param parent [Prism::Node, nil] parent of `node`, or nil at the root.
      # @return [void]
      def index_parents(node, parent)
        return unless node.is_a?(Prism::Node)

        @parents[node] = parent
        node.compact_child_nodes.each { |child| index_parents(child, node) }
      end

      # Returns whether this call is an `each` or `map` whose value is discarded.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [Boolean] true when the swap would be equivalent.
      def unused_result?(node)
        UNUSED_RESULT_NAMES.include?(node.name) && !result_used?(node)
      end

      # Returns whether any syntax reads this node's value.
      #
      # The method body, a block body, and a lambda body count as read: a
      # caller may use the method's return value, and the method that takes
      # a block may use the block's result. The operator does not guess
      # which methods do. A condition, an assignment, an argument, and a
      # receiver count as read even when the outer expression is discarded.
      # A `while`, `until`, or `for` body does not, and neither does `ensure`
      # or `defined?`.
      #
      # @param node [Prism::Node] node whose value may flow outward.
      # @return [Boolean] true when the value is observable.
      def result_used?(node)
        parent = @parents[node]
        return true if parent.nil?

        case parent
        when Prism::StatementsNode
          return false unless parent.body.last.equal?(node)

          result_used?(parent)
        when Prism::IfNode, Prism::UnlessNode
          return true if parent.predicate.equal?(node)

          result_used?(parent)
        when Prism::WhileNode, Prism::UntilNode
          parent.predicate.equal?(node)
        when Prism::ForNode
          !parent.statements.equal?(node)
        when Prism::EnsureNode, Prism::DefinedNode
          false
        when Prism::RescueNode, Prism::WhenNode, Prism::InNode
          return result_used?(parent) if parent.statements.equal?(node)

          true
        when Prism::CaseNode, Prism::CaseMatchNode
          return true if parent.predicate.equal?(node)

          result_used?(parent)
        when Prism::SingletonClassNode
          return true if parent.expression.equal?(node)

          result_used?(parent)
        when Prism::BlockNode, Prism::LambdaNode, Prism::DefNode
          true
        else
          return result_used?(parent) if VALUE_FLOWS.include?(parent.class)

          true
        end
      end
    end
  end
end
