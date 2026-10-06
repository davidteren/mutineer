# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Operator-assignment mutator (Tier-2).
    #
    # Swaps the operator of a compound assignment, one mutation per
    # occurrence: `t += x` -> `t -= x`. Prism parses `t += x` as its own
    # node, not as a CallNode, so the arithmetic mutator never sees it.
    #
    # The mapping is the same as for arithmetic. Other compound operators
    # (`||=`, `&&=`, `|=`, `<<=` and the rest) are not changed.
    class OperatorAssignment < Base
      # Token replacements for compound arithmetic operators.
      REPLACEMENTS = {
        :+ => "-=", :- => "+=", :* => "/=", :/ => "*=", :% => "*=", :** => "*="
      }.freeze

      # Visits `t += x`.
      #
      # @param node [Prism::LocalVariableOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_local_variable_operator_write_node(node)
        emit(node)
        super # the value can hold its own compound assignment
      end

      # Visits `@t += x`.
      #
      # @param node [Prism::InstanceVariableOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_instance_variable_operator_write_node(node)
        emit(node)
        super
      end

      # Visits `@@t += x`.
      #
      # @param node [Prism::ClassVariableOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_class_variable_operator_write_node(node)
        emit(node)
        super
      end

      # Visits `$t += x`.
      #
      # @param node [Prism::GlobalVariableOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_global_variable_operator_write_node(node)
        emit(node)
        super
      end

      # Visits `T += x`.
      #
      # @param node [Prism::ConstantOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_constant_operator_write_node(node)
        emit(node)
        super
      end

      # Visits `A::T += x` and `::T += x`.
      #
      # @param node [Prism::ConstantPathOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_constant_path_operator_write_node(node)
        emit(node)
        super
      end

      # Visits `a.b += x` and `a&.b += x`.
      #
      # @param node [Prism::CallOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_call_operator_write_node(node)
        emit(node)
        super
      end

      # Visits `a[i] += x`.
      #
      # @param node [Prism::IndexOperatorWriteNode] node to inspect.
      # @return [void]
      def visit_index_operator_write_node(node)
        emit(node)
        super
      end

      private

      # Emits a mutation when the node's operator has a replacement.
      #
      # @param node [Prism::Node] a node with `binary_operator` and `binary_operator_loc`.
      # @return [void]
      def emit(node)
        replacement = REPLACEMENTS[node.binary_operator]
        return unless replacement

        loc = node.binary_operator_loc
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: replacement,
          operator: :operator_assignment
        )
      end
    end
  end
end
