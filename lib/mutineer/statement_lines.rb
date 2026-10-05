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
    # @param def_node [Prism::DefNode] the method that holds the position.
    # @param source [String] the source text of the file.
    # @param offset [Integer] byte offset of the position.
    # @return [Array<Integer>] the lines of the statement, with the body of each
    #   heredoc in it. Empty when no statement in the body holds the position.
    #   A first or last line that holds other code is left out, because Ruby
    #   can count that line without the statement: the `def` line counts when
    #   the file loads, and `x if done; y(` counts when `y` does not run.
    def self.for(def_node, source, offset)
      return [] unless def_node.body

      path = path_to(def_node.body, offset) || []
      index = path.rindex(&:newline?)
      return [] unless index

      statement = path[index]
      # Ruby counts the line of `x while c` when it checks `c`, also when `x` never runs.
      # The path is loop, its body, statement.
      return [] if index >= 2 && modifier_loop?(path[index - 2])

      location = statement.location
      lines = (location.start_line..last_line(statement)).to_a
      lines.delete(location.start_line) unless before(source, location).strip.empty?
      after = after(source, location).strip
      lines.delete(location.end_line) unless after.empty? || after.start_with?("#")
      lines
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

    # Whether `node` is a `while` or `until` modifier, such as `x while c`.
    # The body of `begin ... end while c` runs once before the check, so it is not.
    #
    # @param node [Prism::Node, nil] the parent of the body that holds the statement.
    # @return [Boolean]
    def self.modifier_loop?(node)
      return false unless node.is_a?(Prism::WhileNode) || node.is_a?(Prism::UntilNode)
      return false if node.begin_modifier? || node.statements.nil?

      node.statements.location.start_offset < node.keyword_loc.start_offset
    end

    # The text before `location` on its first line.
    #
    # @param source [String]
    # @param location [Prism::Location]
    # @return [String]
    def self.before(source, location)
      source.byteslice(location.start_offset - location.start_column, location.start_column)
    end

    # The text after `location` on its last line.
    #
    # @param source [String]
    # @param location [Prism::Location]
    # @return [String]
    def self.after(source, location)
      source.byteslice(location.end_offset, source.bytesize).each_line.first.to_s
    end
  end
end
