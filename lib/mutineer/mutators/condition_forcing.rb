# frozen_string_literal: true

require_relative "base"
require_relative "statement_removal"
require_relative "return_nil"

module Mutineer
  module Mutators
    # Shared base of the condition-forcing mutators (Tier-2).
    #
    # Replaces the condition of an `if`, `elsif`, `unless`, ternary, modifier
    # guard (`x if y`) or `case`/`in` guard with a literal, so its branch always
    # runs or never runs. {ConditionTrue} forces `true` and {ConditionFalse}
    # forces `false`; one mutation per condition each.
    #
    # Two kinds of condition are left alone, because the mutant would repeat
    # one another operator makes:
    #
    # - A condition that is already `true`, `false` or `nil`: `boolean_literal`
    #   flips it.
    # - The never-runs side of a conditional with no else branch whose whole
    #   expression `statement_removal` or `return_nil` replaces with `nil`, as
    #   in `return x if y` followed by more code: forcing it that way is the
    #   same program. The always-runs side is still made.
    #
    # `condition_negation` wraps the condition in `!( ... )`, which neither
    # forced value is.
    class ConditionForcing < Base
      # Condition nodes that `boolean_literal` already mutates.
      LITERALS = [Prism::TrueNode, Prism::FalseNode, Prism::NilNode].freeze

      # Operators whose `nil` replacement of a whole conditional equals forcing
      # an else-less conditional's branch never to run.
      NILLED_BY = [StatementRemoval, ReturnNil].freeze

      # Keeps the subject for the lazy {#nilled?} lookup, then walks its body.
      #
      # @param subject [Mutineer::Subject] subject whose body is visited.
      # @param source [String] full source text for byte-based slicing.
      # @return [Array<Mutineer::Mutation>] collected mutations.
      def mutations_for(subject, source)
        @subject = subject
        @nilled = nil
        super
      end

      # Visits if nodes: `if`, `elsif`, a ternary, a modifier `if` and an
      # `in ... if` guard.
      #
      # @param node [Prism::IfNode] node to inspect.
      # @return [void]
      def visit_if_node(node)
        force(node, runs: true, otherwise: node.subsequent)
        super
      end

      # Visits unless nodes: `unless`, a modifier `unless` and an
      # `in ... unless` guard.
      #
      # @param node [Prism::UnlessNode] node to inspect.
      # @return [void]
      def visit_unless_node(node)
        force(node, runs: false, otherwise: node.else_clause)
        super
      end

      # Nested method definitions are discovered as their own subjects; do not
      # recurse into them (prevents double-counting their conditions).
      #
      # @param node [Prism::DefNode] nested definition node.
      # @return [void]
      def visit_def_node(node); end

      private

      # Emits the forced condition unless another operator already makes the
      # same program.
      #
      # @param node [Prism::IfNode, Prism::UnlessNode] the conditional.
      # @param runs [Boolean] the condition value that runs the branch.
      # @param otherwise [Prism::Node, nil] the else branch or `elsif`, if any.
      # @return [void]
      def force(node, runs:, otherwise:)
        predicate = node.predicate
        return if LITERALS.any? { |literal| predicate.is_a?(literal) }
        return if self.class::VALUE != runs && otherwise.nil? && nilled?(node)

        loc = predicate.location
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: self.class::VALUE.to_s,
          operator: self.class::OPERATOR
        )
      end

      # Returns whether an operator in {NILLED_BY} replaces this whole node
      # with `nil`. Their mutations are built once per subject, on first use.
      #
      # @param node [Prism::Node] the conditional.
      # @return [Boolean] true when the node's exact range is replaced by nil.
      def nilled?(node)
        @nilled ||= NILLED_BY.flat_map { |klass| klass.new.mutations_for(@subject, @source) }
                             .to_h { |m| [[m.start_offset, m.end_offset], true] }
        loc = node.location
        @nilled.key?([loc.start_offset, loc.end_offset])
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
