# frozen_string_literal: true

require "securerandom"
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
  # A `:run` mutant in a block whose call ran at load carries the same wrapper
  # ({JobPlan.stored_block_candidate?}, #493). There a silent probe moves a
  # survivor to `ran_at_load`, so the caller first asks {conclusive?}.
  #
  # The inserted text is stdlib only (`File`). The daemon loads it as source,
  # so the app process needs no Prism and no Mutineer constant.
  module ReachProbe
    # A fiber-local key for one sentinel: `mutineer_r` plus 16 hex digits.
    # `Thread.current[]` is fiber-local, not one value for the whole thread.
    # The generated source and {forget_load} use this key, not a fixed global,
    # so an application variable of the same shape is not read or overwritten.
    # The daemon checks the same pattern; it cannot load this file.
    KEY_FORMAT = /\Amutineer_r[0-9a-f]{16}\z/

    # A new key for one mutant's sentinel.
    #
    # @return [String]
    def self.reach_key
      "mutineer_r#{SecureRandom.hex(8)}"
    end
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
    # @param key [String, nil] fiber-local key from {reach_key}.
    # @return [void]
    def self.forget_load(path, key)
      return unless path

      Thread.current[key.to_sym] = nil if key.to_s.match?(KEY_FORMAT)
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
    # caller then has no evidence the expression ran. A `:maybe` survivor stays
    # `no_coverage` (#345), and a stored-block candidate keeps its verdict (#493).
    #
    # @param source [String] mutated source.
    # @param mutation [Mutineer::Mutation] the edit, already applied to `source`.
    # @param path [String, nil] sentinel path, or nil to leave `source` alone.
    # @param key [String, nil] fiber-local key from {reach_key}.
    # @return [String]
    def self.wrap_mutation(source, mutation, path, key)
      return source if path.nil? || !key.to_s.match?(KEY_FORMAT)

      start = mutation.start_offset
      wrap(source, start, start + mutation.replacement.bytesize, path, key) || source
    end

    # Jumps that leave an expression before it returns.
    JUMPS = [Prism::NextNode, Prism::BreakNode, Prism::ReturnNode, Prism::RedoNode, Prism::RetryNode].freeze

    # Calls with no receiver that leave an expression before it returns.
    EXITS = %i[raise fail throw exit exit! abort].freeze

    # Whether a silent probe in `code` shows that the mutated expression did
    # not return during a test (#493). True when `code` holds the probe for
    # `key`, the probe is not in a `defined?` operand, and the wrapped
    # expression holds none of {JUMPS} and no call of {EXITS}.
    # {wrap_mutation} and {Isolation.mutated_def} return the text with no
    # probe when the wrap does not parse. A probe around `next if x` or
    # `raise E if x` stays silent each time that exit is taken, though a test
    # ran the mutated code. Ruby never runs the operand of `defined?`. In each
    # case there is no evidence, so the caller keeps the verdict. A raise
    # inside a method that the expression calls cannot be seen in the text, so
    # it is not checked. Plain text plus one parse, so the tool process can
    # ask it about the text it sends to the daemon.
    #
    # @param code [String] the mutant text that the child loads.
    # @param key [String, nil] fiber-local key from {reach_key}.
    # @return [Boolean]
    def self.conclusive?(code, key)
      return false unless key.to_s.match?(KEY_FORMAT)

      at = code.byteindex("(::Thread.current[:#{key}]")
      wrapped = at && wrapped_node(Parser.parse_string(code).value, at)
      !wrapped.nil? && !jump?(wrapped)
    end

    # The expression that the probe at byte offset `mark` wraps: the first
    # element of the two-element array that {splice} builds. Nil when no such
    # array is there, or when it is in the operand of `defined?`.
    #
    # @param node [Prism::Node]
    # @param mark [Integer] byte offset of the mark, the second element.
    # @return [Prism::Node, nil]
    def self.wrapped_node(node, mark)
      return nil if node.is_a?(Prism::DefinedNode)

      if node.is_a?(Prism::ArrayNode) && node.elements.size == 2 && node.elements[1].location.start_offset == mark
        return node.elements[0]
      end

      node.compact_child_nodes.each do |child|
        found = wrapped_node(child, mark)
        return found if found
      end
      nil
    end
    private_class_method :wrapped_node

    # Whether `node` is or holds one of {JUMPS} or a call of {EXITS}. One in a
    # nested lambda counts too: too wide is safe, because the verdict then
    # stays.
    #
    # @param node [Prism::Node]
    # @return [Boolean]
    def self.jump?(node)
      return true if JUMPS.any? { |klass| node.is_a?(klass) }
      return true if node.is_a?(Prism::CallNode) && node.receiver.nil? && EXITS.include?(node.name)

      node.compact_child_nodes.any? { |child| jump?(child) }
    end
    private_class_method :jump?

    # Wraps the smallest expression that holds the byte range `[start_offset,
    # end_offset)`. An empty range is the point where a deletion used to be.
    # Returns nil when no expression holds it, or no wrap is sound ({sound?}):
    # a wrap that does not parse, or that parses as something else, is not
    # used.
    #
    # The wrap never goes around a block or a lambda literal. That literal
    # runs when the block is made, not when its body runs, so a probe there
    # says nothing about the mutated expression in the body (#493). A wrap
    # that cannot stay inside the block gives nil.
    #
    # The wrapper returns the expression's value. It writes the sentinel only
    # after that value has come back, so a raise inside the expression — an
    # operand that fails before a mutated operator runs — does not count as a
    # run. Later returns on the same thread do not touch the file.
    #
    # @param source [String]
    # @param start_offset [Integer] byte offset of the replacement.
    # @param end_offset [Integer] byte offset just after the replacement.
    # @param path [String] absolute sentinel path.
    # @param key [String] fiber-local key from {reach_key}.
    # @return [String, nil]
    def self.wrap(source, start_offset, end_offset, path, key)
      return nil unless key.to_s.match?(KEY_FORMAT)
      root = Parser.parse_string(source).value
      node = smallest(root, start_offset, end_offset)
      return nil unless node

      parents = parent_map(root)
      while node
        break if node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)

        parent = parents[node]
        unless named_capture_part?(parents, node)
          wrapped = splice(source, node, path, key)
          return wrapped if sound?(wrapped, node.location.start_offset)
        end
        break if parent.nil? || climb_stops?(parent, node)

        node = parent
      end
      nil
    end

    # Whether the wrapped text parses, and the wrapper at `offset` is the
    # two-element array that {splice} wrote. A wrap can parse as something
    # else: after a string that a backslash continues, `[` reads as an index
    # call on that string, and inside a string literal it is plain text. Such
    # a wrap changes the program, so it is not used (#493).
    #
    # @param wrapped [String] the text from {splice}.
    # @param offset [Integer] byte offset where the wrapper starts.
    # @return [Boolean]
    def self.sound?(wrapped, offset)
      return false if Parser.invalid?(wrapped)

      array_at?(Parser.parse_string(wrapped).value, offset)
    end
    private_class_method :sound?

    # Whether a two-element array literal starts at byte `offset`.
    #
    # @param node [Prism::Node]
    # @param offset [Integer]
    # @return [Boolean]
    def self.array_at?(node, offset)
      return true if node.is_a?(Prism::ArrayNode) && node.location.start_offset == offset && node.elements.size == 2

      node.compact_child_nodes.any? { |child| array_at?(child, offset) }
    end
    private_class_method :array_at?

    # Whether `node` is a part of a match that assigns named captures
    # (`/(?<year>\d+)/ =~ s`): the regexp literal on the left, or a capture
    # target, which has the span of that literal. Ruby assigns the captures to
    # local variables only when the literal itself is the receiver, so the
    # wrap goes around the whole match (#493).
    #
    # @param parents [Hash{Prism::Node => Prism::Node}] from {parent_map}.
    # @param node [Prism::Node]
    # @return [Boolean]
    def self.named_capture_part?(parents, node)
      parent = parents[node]
      return true if parent.is_a?(Prism::MatchWriteNode)

      parent.is_a?(Prism::CallNode) && parent.receiver.equal?(node) && parents[parent].is_a?(Prism::MatchWriteNode)
    end
    private_class_method :named_capture_part?

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
    # when `node` raises. The array starts where `node` started, on the same
    # line. A line break before it would end a `return`, `next`, `break` or a
    # command call with no parentheses that takes `node` as its value, and the
    # text would still parse (#493).
    #
    # @param source [String]
    # @param node [Prism::Node]
    # @param path [String]
    # @param key [String] fiber-local key from {reach_key}.
    # @return [String]
    def self.splice(source, node, path, key)
      loc = node.location
      inner = source.byteslice(loc.start_offset, loc.end_offset - loc.start_offset)
      quoted = path.dump
      # The fiber-local skips the write after the first return on this
      # fiber. A stat on every later pass would hit a loop.
      # `::Thread` and `::File`: a namespace can hold its own constant of that name.
      mark = "(::Thread.current[:#{key}] ||= (::File.write(#{quoted}, \"1\"); true))"
      source.byteslice(0, loc.start_offset) + "[(#{inner}), #{mark}][0]" + source.byteslice(loc.end_offset..)
    end
    private_class_method :splice
  end
end
