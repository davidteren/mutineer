# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Collection / enumerable method-name mutator (Tier-2).
    #
    # Swaps the method-name token of a call to its semantic opposite, one
    # mutation per occurrence, exactly like the arithmetic/comparison operators.
    #
    # Every swap except `all?` / `any?` is declined when the value is
    # discarded as a statement of its own (a `min` / `max` with a block and a
    # `select` / `reject` with arguments stay). `each` returns its receiver and `map` a new array. `select`
    # and `reject` walk every element. `first` / `last` and `min` / `max`
    # differ only in the value they return. No test can tell such a mutant
    # from the original. `all?` and `any?` stop on different elements, so a
    # block can show the change even when the boolean is discarded. A
    # truthiness-only read of `each`, `map`, or an argument-free `select` or
    # `reject` is declined too (#468, #501).
    # `first` has no `last` on a Hash or a Set, so that decline can hide a
    # mutant that raises `NoMethodError` (#501).
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

      # Names whose swap changes the returned value and not the walk.
      # A call whose value is discarded is declined. The check is the syntax tree only:
      # it does not know the receiver's class. `all?` and `any?` are not
      # here: they stop on different elements.
      DISCARDABLE_NAMES = %i[each map select reject first last min max].freeze

      # Names that a truthiness-only read cannot tell apart. Both results are
      # true for an ordinary receiver. `first` and `min` are not here: their
      # result can be nil.
      TRUTHY_RESULT_NAMES = %i[each map].freeze

      # Names that return an Array, a Hash or an Enumerator, never nil or
      # false, so a truthiness-only read cannot tell the swap apart. An empty
      # Array is true. Only a call with no arguments counts: `IO.select(r)`
      # can return nil.
      TRUTHY_ARRAY_NAMES = %i[select reject].freeze

      # Parents that pass a child's value through. The child is observable
      # exactly when that parent is. An assignment, an argument, a receiver,
      # or an explicit `return` / `break` / `next` is not in this list: those
      # parents use the value even when their own result is discarded.
      # Interpolation is not in this list. A string or symbol calls `to_s`
      # on the value, a backtick command runs, and a regexp is compiled,
      # even when the expression's own result is thrown away. A hash
      # association is not in this list either: its key is hashed on
      # insertion, and its value is handled in {#result_used?}.
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
        Prism::AssocSplatNode,
        Prism::SplatNode,
        Prism::RangeNode,
        Prism::EmbeddedStatementsNode
      ].freeze

      # Parents that only sequence or choose statements. A call whose
      # ancestors are all of these, up to a block, a lambda, or the method,
      # is a statement of its own: no operator, parenthesis, or modifier
      # passes its value on.
      STATEMENT_PARENTS = [
        Prism::StatementsNode, Prism::IfNode, Prism::UnlessNode, Prism::ElseNode,
        Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::CaseNode,
        Prism::CaseMatchNode, Prism::WhenNode, Prism::InNode, Prism::BeginNode,
        Prism::RescueNode, Prism::EnsureNode, Prism::SingletonClassNode
      ].freeze

      # Records parents, then walks the body. The result check needs the
      # parent of each call, and Prism nodes do not store one.
      #
      # @param subject [Mutineer::Subject] subject whose body is visited.
      # @param source [String] full source text for byte-based slicing.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @parents = {}.compare_by_identity
        @lazy_locals = []
        index_parents(subject.def_node.body, nil)
        find_lazy_locals(subject.def_node.body)
        super
      end

      # Visits call nodes and emits collection-method mutations.
      # An {DISCARDABLE_NAMES} call whose value is discarded is declined,
      # and so is an `each`, `map`, or argument-free `select` or `reject` whose
      # value is read only for truthiness.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [void]
      def visit_call_node(node)
        replacement = REPLACEMENTS[node.name]
        loc = node.message_loc
        if replacement && loc
          if equivalent_swap?(node)
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

      # Returns whether this call's swap changes only a value nobody reads.
      # That is an {DISCARDABLE_NAMES} call whose value is discarded, or
      # an `each`, `map`, or argument-free `select` or `reject` whose value is
      # read only for truthiness.
      # A `min` or `max` with a block is kept: the block sees different pairs.
      #
      # Interpolation is not discarded: a string or symbol calls `to_s`, a
      # backtick command runs, and a regexp is compiled. A hash key is not
      # discarded either: insertion calls `hash` and `eql?`. Those nodes are
      # absent from {VALUE_FLOWS}, so {#result_used?} keeps them. A receiver
      # chain that calls `lazy` is kept too. `Enumerator::Lazy#each` runs the
      # block and `Lazy#map` does not, and the syntax tree can see the `lazy`
      # call. A local variable assigned from such a chain in the same method
      # is kept too (#468). A lazy enumerator from a parameter, an instance
      # variable, or a call has no `lazy` call in the method, so it is
      # declined (#501).
      # `defined?` does not evaluate its operand, so a call inside it is
      # discarded even when the chain calls `lazy` or the call sits in an
      # interpolation.
      #
      # @param node [Prism::CallNode] call node to inspect.
      # @return [Boolean] true when the swap would be equivalent.
      def equivalent_swap?(node)
        return false unless DISCARDABLE_NAMES.include?(node.name)
        return true if inside_defined?(node) && TRUTHY_RESULT_NAMES.include?(node.name)
        return false if lazy_value?(node.receiver)

        if TRUTHY_RESULT_NAMES.include?(node.name)
          !result_used?(node) || truthiness_only?(node)
        elsif TRUTHY_ARRAY_NAMES.include?(node.name) && !node.arguments && truthiness_only?(node)
          true
        else
          discarded_statement?(node)
        end
      end

      # Returns whether a `select`, `reject`, `first`, `last`, `min` or `max`
      # call is a statement of its own whose value is discarded.
      #
      # Only a statement of its own counts here. A truthiness-only read is
      # handled by {#truthiness_only?}. A call inside `&&`, `||`,
      # parentheses, a rescue modifier, or `defined?` is kept: its value can
      # decide a branch, and `defined?` asks whether the method exists. A
      # `min` or `max` with a block, or with `...` that may forward one, is kept:
      # the block sees different pairs.
      # So is a `select` or `reject` with arguments, because
      # `Enumerable#select` takes none and `IO.select(readers)` is another
      # method.
      #
      # @param node [Prism::CallNode] call to inspect.
      # @return [Boolean] true when the swap would be equivalent.
      def discarded_statement?(node)
        return false if %i[min max].include?(node.name) && (node.block || forwards_arguments?(node))
        return false if %i[select reject].include?(node.name) && node.arguments

        statement_of_its_own?(node) && !result_used?(node)
      end

      # Returns whether the call forwards `...`, which can carry a comparator block.
      #
      # @param node [Prism::CallNode] call to inspect.
      # @return [Boolean] true when an argument is `...`.
      def forwards_arguments?(node)
        node.arguments&.arguments&.any?(Prism::ForwardingArgumentsNode) || false
      end

      # Returns whether every ancestor, up to a block, a lambda, or the method
      # body, is in {STATEMENT_PARENTS}.
      #
      # @param node [Prism::Node] node to inspect.
      # @return [Boolean] true when no expression passes the value on.
      def statement_of_its_own?(node)
        current = node
        while (parent = @parents[current])
          break if parent.is_a?(Prism::BlockNode) || parent.is_a?(Prism::LambdaNode)
          return false unless STATEMENT_PARENTS.include?(parent.class)

          current = parent
        end
        true
      end

      # Returns whether only the truthiness of the call's value is read.
      #
      # The condition of `if`, `unless`, `while`, `until`, the left side of
      # `&&` / `and`, and a `when` condition of a `case` with no subject all
      # test the value. A successful `each`, `map`, `select` or `reject` is
      # never false, so the swap cannot change the branch. The climb goes up
      # through parentheses, either side of `||` / `or`, and the right side of
      # `&&` / `and`, when that larger expression is itself only tested, as in
      # `if a && xs.each { }` (#501). The left side of `||` / `or` is
      # excluded when the result is kept: that operator returns the value. A
      # `case` subject is excluded too: `when Hash` is `Hash === value`, and
      # `each` and `map` return a Hash and an Array for a Hash receiver.
      #
      # @param node [Prism::Node] call or enclosing expression to inspect.
      # @return [Boolean] true when only the truthiness is read.
      def truthiness_only?(node)
        parent = @parents[node]
        case parent
        when Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode
          parent.predicate.equal?(node)
        when Prism::AndNode
          parent.left.equal?(node) || truthiness_only?(parent)
        when Prism::OrNode
          truthiness_only?(parent)
        when Prism::StatementsNode
          parent.body.last.equal?(node) && @parents[parent].is_a?(Prism::ParenthesesNode) &&
            truthiness_only?(@parents[parent])
        when Prism::WhenNode
          @parents[parent].predicate.nil? && parent.conditions.any? { |condition| condition.equal?(node) }
        else
          false
        end
      end

      # Returns whether `node` is inside a `defined?` operand.
      #
      # `defined?` does not run that operand, so an `each` or `map` there
      # does not call `to_s`, run a command, or compile a regexp.
      #
      # @param node [Prism::Node] node to inspect.
      # @return [Boolean] true when an ancestor is a DefinedNode.
      def inside_defined?(node)
        current = node
        while (current = @parents[current])
          return true if current.is_a?(Prism::DefinedNode)
        end
        false
      end

      # Collects the local variables that hold a lazy enumerator.
      #
      # A variable counts when any assignment in the method (`=`, `||=`,
      # `&&=`, or multiple assignment) gives it a value that is a lazy chain
      # or a lazy local, see {#lazy_value?}. Order and branches are ignored:
      # when the tree cannot tell, the swap stays. Multiple assignment marks
      # every local target, because the tree does not pair them reliably.
      #
      # @param body [Prism::Node, nil] method body.
      # @return [void]
      def find_lazy_locals(body)
        writes = []
        collect_local_writes(body, writes)
        loop do
          found = writes.select { |names, value| (names - @lazy_locals).any? && lazy_value?(value) }
          break if found.empty?

          @lazy_locals.concat(found.flat_map(&:first))
        end
      end

      # Gathers `[names, value]` for every local assignment under `node`.
      #
      # @param node [Prism::Node, nil] subtree to scan.
      # @param writes [Array<Array>] receives `[local names, value node]` pairs.
      # @return [void]
      def collect_local_writes(node, writes)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
          writes << [[node.name], node.value]
        when Prism::ForNode
          names = []
          names << node.index.name if node.index.is_a?(Prism::LocalVariableTargetNode)
          collect_target_names(node.index, names)
          writes << [names, node.collection]
        when Prism::MultiWriteNode
          names = []
          collect_target_names(node, names)
          writes << [names, node.value]
        end
        node.compact_child_nodes.each { |child| collect_local_writes(child, writes) }
      end

      # Gathers the names of every local target in a multiple assignment,
      # including nested targets such as `(a, b), c = ...`.
      #
      # @param node [Prism::Node] multiple assignment, or a target inside one.
      # @param names [Array<Symbol>] receives the local names.
      # @return [void]
      def collect_target_names(node, names)
        node.compact_child_nodes.each do |child|
          next if child.equal?(node.respond_to?(:value) ? node.value : nil)

          names << child.name if child.is_a?(Prism::LocalVariableTargetNode)
          collect_target_names(child, names)
        end
      end

      # Returns whether an assigned value may be a lazy enumerator.
      #
      # It may be when the value holds a `lazy` call or a read of a lazy
      # local anywhere in its subtree (`xs.lazy`, `(xs.lazy)`, a ternary
      # branch, `begin`, `case`, `a = b = xs.lazy`). This over-approximates:
      # `xs.lazy.to_a` counts too, and the swap then stays. A value from a
      # parameter, an instance variable, or another call shows no `lazy` call.
      #
      # @param value [Prism::Node, nil] right side of an assignment.
      # @return [Boolean] true when the value may be a lazy enumerator.
      def lazy_value?(value)
        return false unless value.is_a?(Prism::Node)
        return true if value.is_a?(Prism::CallNode) && value.name == :lazy
        return true if value.is_a?(Prism::LocalVariableReadNode) && @lazy_locals.include?(value.name)

        value.compact_child_nodes.any? { |child| lazy_value?(child) }
      end

      # Returns whether any syntax reads this node's value.
      #
      # The method body, a block body, and a lambda body count as read: a
      # caller may use the method's return value, and the method that takes
      # a block may use the block's result. The operator does not guess
      # which methods do. A condition, an assignment, an argument, and a
      # receiver count as read even when the outer expression is discarded.
      # {#truthiness_only?} tells a condition read only for truthiness.
      # A `while` or `until` body does not, and neither does `ensure` or
      # `defined?`. A `for` body does not either: `for` returns the
      # collection, not the body. A hash key is read on insertion. The value
      # of a hash pair follows the hash. A later `rescue` clause follows the
      # `begin`, the same way the first clause does.
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
          # `for` returns the collection, not the body.
          !parent.statements.equal?(node)
        when Prism::EnsureNode, Prism::DefinedNode
          false
        when Prism::AssocNode
          return true if parent.key.equal?(node)

          result_used?(parent)
        when Prism::RescueNode
          if parent.statements.equal?(node) || parent.subsequent.equal?(node)
            result_used?(parent)
          else
            true
          end
        when Prism::WhenNode, Prism::InNode
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
