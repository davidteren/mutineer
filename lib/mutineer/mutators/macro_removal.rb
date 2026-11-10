# frozen_string_literal: true

require_relative "macro_base"

module Mutineer
  module Mutators
    # Replaces one class-body macro call, including its block, with `nil`.
    class MacroRemoval < MacroBase
      # Replaces the subject call. Nested calls are not separate subjects.
      #
      # @param node [Prism::CallNode] call to inspect.
      # @return [void]
      def visit_call_node(node)
        return unless node.equal?(@body)

        loc = node.location
        @mutations << Mutation.new(
          start_offset: loc.start_offset,
          end_offset: loc.end_offset,
          replacement: "nil",
          operator: :macro_removal
        )
      end
    end
  end
end
