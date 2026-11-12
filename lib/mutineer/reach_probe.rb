# frozen_string_literal: true

require "tempfile"
require_relative "parser"
require_relative "statement_lines"

module Mutineer
  # Records whether the expression that holds a mutation ran in the child.
  #
  # Ruby counts one line of a statement. A mutant on another line is selected
  # as `:maybe` (#254, #289): the tests of the statement may not have reached
  # it. A kill is still a kill. A survivor used to stay `no_coverage`, because
  # the line count cannot tell "ran" from "did not run". The wrapper below
  # writes a sentinel when that expression runs, so a survivor that ran counts
  # as `survived` and one that did not stays `no_coverage` (#345).
  #
  # The inserted text is stdlib only (`File`). The daemon loads it as source,
  # so the app process needs no Prism and no Mutineer constant.
  module ReachProbe
    # Global the generated source sets after the expression returns once.
    # {forget_load} and the daemon's `forget_load_reach` clear this same
    # name, so a load-time run does not skip the write during the tests.
    # The daemon hardcodes the name: it cannot load this file.
    REACHED = :$mutineer_reached
    # An empty sentinel file. The child writes `"1"` when the expression runs.
    # The caller checks {reached?} and then {close_sentinel}.
    #
    # @return [Tempfile]
    def self.sentinel
      file = Tempfile.new(["mutineer-reach-", ".touch"])
      file.close
      file
    end

    # Whether a test wrote the sentinel after {forget_load}. False when there
    # is no sentinel, or the expression did not return during a test.
    #
    # @param sentinel [Tempfile, nil]
    # @return [Boolean]
    def self.reached?(sentinel)
      !sentinel.nil? && File.size(sentinel.path).positive?
    end

    # Empties the sentinel after the mutant has loaded and before its tests
    # run. A reload runs top-level calls, and those can reach the expression
    # before any test does. That load is not a test reaching it (#345). The
    # daemon does the same clear itself, because this file pulls in Prism and
    # the daemon cannot.
    #
    # @param path [String, nil] sentinel path.
    # @return [void]
    def self.forget_load(path)
      return unless path

      # Same name as {REACHED}. A direct write: this file must not eval.
      $mutineer_reached = nil
      File.write(path, "")
    end

    # Removes the sentinel file. A missing file is already gone.
    #
    # @param sentinel [Tempfile, nil]
    # @return [void]
    def self.close_sentinel(sentinel)
      return unless sentinel

      sentinel.close unless sentinel.closed?
      sentinel.unlink
    rescue Errno::ENOENT
      nil
    end

    # The mutated source with a probe around the expression that holds the
    # replacement, or `source` when `path` is nil. The original source when
    # the expression cannot be wrapped without changing how it parses: the
    # caller then has no evidence the expression ran, and a survivor stays
    # `no_coverage`.
    #
    # @param source [String] mutated source.
    # @param mutation [Mutineer::Mutation] the edit, already applied to `source`.
    # @param path [String, nil] sentinel path, or nil to leave `source` alone.
    # @return [String]
    def self.wrap_mutation(source, mutation, path)
      return source if path.nil?

      start = mutation.start_offset
      wrap(source, start, start + mutation.replacement.bytesize, path) || source
    end

    # Wraps the smallest expression that holds the byte range `[start_offset,
    # end_offset)`. An empty range is the point where a deletion used to be.
    # Returns nil when no expression holds it, or the wrapped text does not
    # parse: a wrap that does not parse is not used.
    #
    # The wrapper returns the expression's value. It writes the sentinel only
    # after that value has come back, so a raise inside the expression — an
    # operand that fails before a mutated operator runs — does not count as a
    # run. It writes once; later evaluations only stat the file.
    #
    # @param source [String]
    # @param start_offset [Integer] byte offset of the replacement.
    # @param end_offset [Integer] byte offset just after the replacement.
    # @param path [String] absolute sentinel path.
    # @return [String, nil]
    def self.wrap(source, start_offset, end_offset, path)
      root = Parser.parse_string(source).value
      node = smallest(root, start_offset, end_offset)
      return nil unless node

      parents = parent_map(root)
      while node
        wrapped = splice(source, node, path)
        return wrapped unless Parser.invalid?(wrapped)

        parent = parents[node]
        break if parent.nil? || climb_stops?(parent, node)

        node = parent
      end
      nil
    end

    # True when wrapping `parent` would record a run of code that can run
    # without `child`: a conditional child, or a node that is a whole def,
    # class, or file.
    #
    # @param parent [Prism::Node]
    # @param child [Prism::Node]
    # @return [Boolean]
    def self.climb_stops?(parent, child)
      return true if CLIMB_STOP.any? { |klass| parent.is_a?(klass) }

      StatementLines.sometimes?(parent, child)
    end
    private_class_method :climb_stops?

    # Nodes that must not be wrapped. Wrapping one records every run of the
    # method or file, not the mutated expression.
    CLIMB_STOP = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::ProgramNode,
                  Prism::SingletonClassNode].freeze

    # Parent of each node, by identity. A heredoc body is a child that lies
    # outside its opener, so every child is recorded.
    #
    # @param root [Prism::Node]
    # @return [Hash{Prism::Node => Prism::Node}]
    def self.parent_map(root)
      map = {}.compare_by_identity
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)

        node.compact_child_nodes.each do |child|
          map[child] = node
          walk.call(child)
        end
      end
      walk.call(root)
      map
    end
    private_class_method :parent_map

    # The deepest node whose location holds the range. A child replaces a
    # parent of the same span, so a one-statement body wraps the statement
    # and not the statement list around it. A heredoc body is a child that
    # lies outside its opener, so every child is searched.
    #
    # @param node [Prism::Node, Object]
    # @param start_offset [Integer]
    # @param end_offset [Integer]
    # @param best [Prism::Node, nil]
    # @return [Prism::Node, nil]
    def self.smallest(node, start_offset, end_offset, best = nil)
      return best unless node.is_a?(Prism::Node)

      loc = node.location
      span = loc.end_offset - loc.start_offset
      covers = if start_offset == end_offset
                 loc.start_offset <= start_offset && start_offset < loc.end_offset
               else
                 span.positive? && loc.start_offset <= start_offset && end_offset <= loc.end_offset
               end
      best = node if covers && (best.nil? || span <= (best.location.end_offset - best.location.start_offset))
      node.compact_child_nodes.each do |child|
        best = smallest(child, start_offset, end_offset, best)
      end
      best
    end
    private_class_method :smallest

    # Replaces `node` with an expression that writes `path` only when `node`
    # returns. The mark is the second element of an array, so it does not run
    # when `node` raises. A one-line node stays one line. A node that spans
    # lines keeps its text and puts the array on the following lines, so the
    # indent warning stays quiet.
    #
    # @param source [String]
    # @param node [Prism::Node]
    # @param path [String]
    # @return [String]
    def self.splice(source, node, path)
      loc = node.location
      inner = source.byteslice(loc.start_offset, loc.end_offset - loc.start_offset)
      quoted = path.dump
      # The global skips the write after the first return. A stat on every
      # later pass would hit a loop that evaluates the expression.
      mark = "(#{REACHED} ||= (::File.write(#{quoted}, \"1\"); true))"
      replacement = if inner.include?("\n")
                      "\n[(#{inner}), #{mark}][0]"
                    else
                      "[(#{inner}), #{mark}][0]"
                    end
      source.byteslice(0, loc.start_offset) + replacement + source.byteslice(loc.end_offset..)
    end
    private_class_method :splice
  end
end
