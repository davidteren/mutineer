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
      # Code that runs only sometimes inside the statement: the tests that ran
      # the statement need not have run it.
      return [] if path[index..].each_cons(2).any? { |parent, child| sometimes?(parent, child) }

      # Ruby counts the line of `x while c` or `x if c` when it checks `c`,
      # also when `x` never runs. The path is the modifier, its body, statement.
      return [] if index >= 2 && modifier?(path[index - 2])

      location = statement.location
      lines = (location.start_line..last_line(statement)).to_a
      lines.delete(location.start_line) unless before(source, location).strip.empty?
      after = after(source, location).strip
      lines.delete(location.end_line) unless after.empty? || after.start_with?("#")
      lines
    end

    # Whether the code at `offset` runs each time the method runs: it is in
    # the first statement of the body, not in a statement nested in it or in
    # a {NESTED} node (a block or loop body), and not in code that runs only
    # sometimes ({sometimes?}, the body of `x if c`). The first statement in
    # parentheses or `begin ... end` runs with them, so it counts
    # ({grouped_first?}). Used for a method whose body shares the `def` line,
    # where only the method's call count tells that the code ran (#209).
    #
    # @param def_node [Prism::DefNode] the method that holds the position.
    # @param offset [Integer] byte offset of the position.
    # @return [Boolean]
    def self.runs_with_method?(def_node, offset)
      first = def_node.body.is_a?(Prism::StatementsNode) && def_node.body.body.first
      path = first && path_to(first, offset)
      return false unless path

      return false if path.drop(1).any? { |node| NESTED.any? { |klass| node.is_a?(klass) } }
      return false if path[1]&.newline?

      path.each_cons(3).none? { |grand, parent, node| node.newline? && !grouped_first?(grand, parent, node) } &&
        path.each_cons(2).none? { |parent, child| sometimes?(parent, child) }
    end

    # Whether `node` is the first statement in parentheses or `begin ... end`,
    # which runs each time they do.
    #
    # @param grand [Prism::Node] the parent of `parent`.
    # @param parent [Prism::Node] the parent of `node`.
    # @param node [Prism::Node]
    # @return [Boolean]
    def self.grouped_first?(grand, parent, node)
      (grand.is_a?(Prism::ParenthesesNode) || grand.is_a?(Prism::BeginNode)) &&
        parent.is_a?(Prism::StatementsNode) && parent.body.first.equal?(node)
    end

    # Nodes whose code can run any number of times, or not at all, when the
    # statement that holds them runs.
    NESTED = [Prism::BlockNode, Prism::LambdaNode, Prism::WhileNode, Prism::UntilNode, Prism::ForNode,
              Prism::DefNode].freeze

    # Nodes whose code runs only when a branch, a match or an exception picks
    # it: a `when` or `in` clause (its condition or pattern), a `rescue` clause
    # (its class list), an `else` branch, parameters (their defaults) and
    # `defined?` (its operand never runs). A statement in their bodies is a statement of its own, found
    # deeper on the path.
    SOMETIMES = [Prism::WhenNode, Prism::InNode, Prism::RescueNode, Prism::ElseNode, Prism::ParametersNode,
                 Prism::BlockParametersNode, Prism::DefinedNode].freeze

    # Whether `child` runs only sometimes when `parent` runs. Besides the
    # {SOMETIMES} nodes: a branch of an `if`/`unless` inside the statement (a
    # ternary, or `if c then a else b end` on the statement's lines), the
    # rescue side of `x rescue y`, the pattern of `v in p` or `v => p`, the value of
    # `a ||= v` or `a &&= v`, the right side of `a || b` or `a && b`, and the
    # arguments and block of `x&.m(...)` and the value of `x&.m += v`, which do
    # not run when `x` is nil.
    #
    # @param parent [Prism::Node]
    # @param child [Prism::Node]
    # @return [Boolean]
    def self.sometimes?(parent, child)
      return true if SOMETIMES.any? { |klass| child.is_a?(klass) }
      return !child.equal?(parent.predicate) if parent.is_a?(Prism::IfNode) || parent.is_a?(Prism::UnlessNode)
      # A pattern stops at its first part that does not match (`v in 1 | 2`).
      if parent.is_a?(Prism::MatchPredicateNode) || parent.is_a?(Prism::MatchRequiredNode)
        return child.equal?(parent.pattern)
      end
      return child.equal?(parent.rescue_expression) if parent.is_a?(Prism::RescueModifierNode)
      return child.equal?(parent.right) if parent.is_a?(Prism::OrNode) || parent.is_a?(Prism::AndNode)
      if parent.is_a?(Prism::CallNode) && parent.safe_navigation?
        return child.equal?(parent.arguments) || child.equal?(parent.block)
      end
      # `a&.b += v` skips `v` when `a` is nil, like `a&.b ||= v`.
      return true if parent.respond_to?(:safe_navigation?) && parent.safe_navigation? &&
                     parent.respond_to?(:value) && child.equal?(parent.value)

      parent.class.name.end_with?("OrWriteNode", "AndWriteNode") && child.equal?(parent.value)
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

    # Whether `node` is a modifier whose body comes before its keyword, such
    # as `x while c` or `x if c`. The body of `begin ... end while c` runs once
    # before the check, so it is not.
    #
    # @param node [Prism::Node, nil] the parent of the body that holds the statement.
    # @return [Boolean]
    def self.modifier?(node)
      keyword =
        case node
        when Prism::WhileNode, Prism::UntilNode then node.keyword_loc unless node.begin_modifier?
        when Prism::IfNode then node.if_keyword_loc
        when Prism::UnlessNode then node.keyword_loc
        end
      return false if keyword.nil? || node.statements.nil?

      node.statements.location.start_offset < keyword.start_offset
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
