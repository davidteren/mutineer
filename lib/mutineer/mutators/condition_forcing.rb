# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Shared base of the condition-forcing mutators (Tier-2).
    #
    # Replaces the condition of an `if`, `elsif`, `unless`, ternary, modifier
    # guard (`x if y`) or `case`/`in` guard with a literal, so its branch always
    # runs or never runs. {ConditionTrue} forces `true` and {ConditionFalse}
    # forces `false`; one mutation per condition each.
    #
    # A condition that is already `true`, `false` or `nil`, even in
    # parentheses, is left alone: forcing it changes nothing or repeats the
    # `boolean_literal` flip. This holds even when `boolean_literal` does not run.
    # A condition that holds a heredoc is left alone too: the heredoc body lies
    # outside the condition, so it would stay behind as code. A condition that
    # assigns a variable keeps its code and only its value is forced.
    #
    # The never-runs side of an else-less conditional can be the same program
    # as the `nil` that `statement_removal` or `return_nil` puts in place of the
    # whole conditional. It is still made: dropping it would make the mutants
    # of one operator depend on which other operators run, and on what the user
    # suppressed for them. The two then get the same verdict.
    #
    # `condition_negation` wraps the condition in `!( ... )`, which neither
    # forced value is.
    class ConditionForcing < Base
      # Condition nodes that `boolean_literal` already mutates.
      LITERALS = [Prism::TrueNode, Prism::FalseNode, Prism::NilNode].freeze

      # Visits if nodes: `if`, `elsif`, a ternary, a modifier `if` and an
      # `in ... if` guard.
      #
      # @param node [Prism::IfNode] node to inspect.
      # @return [void]
      def visit_if_node(node)
        force(node)
        super
      end

      # Visits unless nodes: `unless`, a modifier `unless` and an
      # `in ... unless` guard.
      #
      # @param node [Prism::UnlessNode] node to inspect.
      # @return [void]
      def visit_unless_node(node)
        force(node)
        super
      end

      private

      # Emits the forced condition unless the condition is a literal or holds a
      # heredoc, whose body would stay behind as code.
      #
      # @param node [Prism::IfNode, Prism::UnlessNode] the conditional.
      # @return [void]
      def force(node)
        predicate = node.predicate
        return if LITERALS.include?(unwrap(predicate).class) || heredoc?(predicate)

        loc = predicate.location
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: replacement(predicate),
          operator: self.class::OPERATOR
        )
      end

      # Returns the forced value for the condition, always in parentheses, so it
      # cannot fuse with a keyword or a `?` next to it: `x if@a` becomes
      # `x if(true)` and `@a?1:2` becomes `(true)?1:2`. A condition that assigns
      # a variable keeps its code, so later reads still see the variable:
      # `(m = x; true)`.
      #
      # @param predicate [Prism::Node] the condition.
      # @return [String] the replacement source.
      def replacement(predicate)
        value = self.class::VALUE.to_s
        writes?(predicate) ? "(#{predicate.slice}; #{value})" : "(#{value})"
      end

      # Returns whether the node writes a variable or constant anywhere inside
      # it: a local, instance, class or global variable, or a constant, in a
      # plain, compound, multiple or pattern write, or a named regex capture.
      #
      # @param node [Prism::Node] the node to inspect.
      # @return [Boolean] true when a write or target node is inside.
      def writes?(node)
        return true if node.type.name.end_with?("_write_node", "_target_node")

        node.compact_child_nodes.any? { |child| writes?(child) }
      end

      # Returns the node inside parentheses that hold exactly one expression,
      # so `(true)` and `((true))` read as `true`.
      #
      # @param node [Prism::Node] the condition.
      # @return [Prism::Node] the innermost wrapped node, or `node` itself.
      def unwrap(node)
        body = node.body if node.is_a?(Prism::ParenthesesNode)
        body = body.body.first if body.is_a?(Prism::StatementsNode) && body.body.size == 1
        body && !body.is_a?(Prism::StatementsNode) ? unwrap(body) : node
      end
    end

    # Condition-forcing mutator: the condition becomes `true` (Tier-2).
    #
    # An `if` branch always runs; an `unless` branch never runs. The mutant
    # survives when no test runs the code with the condition false (for an
    # `if`) or true (for an `unless`) and checks what changes.
    class ConditionTrue < ConditionForcing
      # The literal the condition is replaced with.
      VALUE = true
      # The operator name mutations carry.
      OPERATOR = :condition_true
    end

    # Condition-forcing mutator: the condition becomes `false` (Tier-2).
    #
    # An `if` branch never runs; an `unless` branch always runs. The mutant
    # survives when no test needs the branch the condition guards (for an
    # `if`) or skips it (for an `unless`).
    class ConditionFalse < ConditionForcing
      # The literal the condition is replaced with.
      VALUE = false
      # The operator name mutations carry.
      OPERATOR = :condition_false
    end
  end
end
