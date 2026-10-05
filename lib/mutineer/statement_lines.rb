# frozen_string_literal: true

module Mutineer
  # The lines of the statement that holds a position in a method body.
  #
  # Ruby counts one line of a statement only. A position on another line of a
  # multi-line statement has no count of its own, but the tests that ran the
  # statement ran it. Prism marks the statements (`Node#newline?`), so the
  # nearest marked ancestor of the position is the statement. The caller reads
  # the counts on the lines of the statement; a line Ruby does not count has none.
  module StatementLines
    # @param def_node [Prism::DefNode] the method that holds the position. Its
    #   parse result must have its statements marked (`ParseResult#mark_newlines!`).
    # @param offset [Integer] byte offset of the position.
    # @return [Range, nil] the lines of the statement, with the body of each
    #   heredoc in it, or nil when no statement in the body holds the position.
    #   The `def` is not a statement of the body: Ruby counts its line when the
    #   file loads.
    def self.for(def_node, offset)
      return unless def_node.body

      path = path_to(def_node.body, offset) || []
      statement = path.reverse.find(&:newline?)
      return unless statement

      statement.location.start_line..last_line(statement)
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

    # The last line of `node` and its children. A heredoc body ends below the
    # node of its opener.
    #
    # @param node [Prism::Node]
    # @return [Integer]
    def self.last_line(node)
      [node.location.end_line, *node.compact_child_nodes.map { |child| last_line(child) }].max
    end
  end
end
