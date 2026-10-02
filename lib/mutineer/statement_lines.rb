# frozen_string_literal: true

module Mutineer
  # The lines of the statement that holds a position in a method body.
  #
  # Ruby counts a line at the start of a statement only. A position on a later
  # line of a multi-line statement has no count of its own, but the tests that
  # ran the statement ran it. Prism marks the statements (`Node#newline?`), so
  # the nearest marked ancestor of the position is the statement.
  module StatementLines
    # @param def_node [Prism::DefNode] the method that holds the position.
    # @param source [String] the source text of the file.
    # @param offset [Integer] byte offset of the position.
    # @return [Range, nil] the lines of the statement, or nil when no statement
    #   in the body holds the position. The body of an endless method has none of
    #   its own, so its statement is the `def`.
    def self.for(def_node, source, offset)
      path = path_to(def_node, offset) || []
      # Ruby counts no line for an expression inside `#{...}`, so the statement is outside it.
      path = path.take_while { |node| !node.is_a?(Prism::EmbeddedStatementsNode) }
      statement = path.reverse.find(&:newline?)
      return unless statement

      statement.location.start_line..statement.location.end_line
    end

    # The nodes from `node` down to the deepest one that holds the offset. A
    # heredoc body lies outside the node of its opener, so a child is searched
    # even when its parent does not hold the offset.
    #
    # @param node [Prism::Node]
    # @param offset [Integer] byte offset.
    # @return [Array<Prism::Node>, nil] nil when no node in the subtree holds it.
    def self.path_to(node, offset)
      node.compact_child_nodes.each do |child|
        path = path_to(child, offset)
        return [node, *path] if path
      end
      location = node.location
      [node] if location.start_offset <= offset && offset < location.end_offset
    end
  end
end
