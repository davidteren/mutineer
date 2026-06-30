# frozen_string_literal: true

require_relative "base"

module Mutineer
  module Mutators
    # Boolean connector mutator.
    #
    # Replaces symbolic and keyword connectors with their opposite form.
    class BooleanConnector < Base
      # Token replacements for boolean connectors.
      REPLACEMENTS = { "&&" => "||", "||" => "&&", "and" => "or", "or" => "and" }.freeze

      # Visits `and` nodes.
      #
      # @param node [Prism::AndNode] node to inspect.
      # @return [void]
      def visit_and_node(node)
        emit(node)
        super
      end

      # Visits `or` nodes.
      #
      # @param node [Prism::OrNode] node to inspect.
      # @return [void]
      def visit_or_node(node)
        emit(node)
        super
      end

      private

      # Emits a connector mutation when the token is replaceable.
      #
      # @param node [Prism::Node] connector node.
      # @return [void]
      def emit(node)
        loc = node.operator_loc
        replacement = REPLACEMENTS[loc.slice]
        return unless replacement

        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: replacement,
          operator: :boolean_connector
        )
      end
    end
  end
end
