# frozen_string_literal: true

require "tempfile"
require_relative "result"
require_relative "parser"
require_relative "child_stdout"
require_relative "child_coverage"
require_relative "kill_channel"
require_relative "concern_blocks"
require_relative "redaction"
require_relative "child_cause"

module Mutineer
  # Fork-based isolation for running one mutant. The block runs in a child
  # process; the parent enforces a wall-clock timeout and decodes the child's
  # exit status into a Result.
  #
  # Exit-status contract (the block's return value, or an explicit exit, is the
  # child's status): 0 => survived, 1 => killed, 2 => error. Timeout is
  # detected by the parent's monitor flag, not by status.signaled? (which is
  # true for ANY signal death, e.g. SIGSEGV — it cannot tell our SIGKILL apart
  # from the OS's).
  #
  # mutineer: the reload strategy this enables (whole-file `load`) re-executes
  # the entire file — any top-level code runs again. Acceptable for POROs;
  # document if users hit issues with initializers/callbacks. Alternative: the
  # redefine strategy (surgical single-method redefinition).
  class Isolation
    DEFAULT_TIMEOUT = 10 # seconds

    # Seconds between the parent's checks on a running child.
    POLL_INTERVAL = 0.005

    # Byte scan for a path anchor. A snippet without one skips the parse that
    # {anchor_paths} would do (#339). `send(:__dir__)` and
    # `send(:require_relative)` contain the same tokens.
    ANCHOR_PATTERN = /__dir__|__FILE__|require_relative/

    # Runs the block in a forked child. The block's return value (an Integer
    # exit code) or any explicit `exit` is honoured; an unhandled exception
    # becomes exit 2 with the cause written to STDERR. The cause also reaches
    # the Result's `details` through a {ChildCause} pipe.
    #
    # The child silences its stdout (see {ChildStdout.silence}) before the
    # block runs, so test output never reaches the user. Stderr stays open.
    #
    # With `channel: true` (a `--matrix` run) the block gets the write end of a
    # pipe for {KillChannel} lines. The parent reads it while it waits, so a
    # child with more than a pipe buffer to say never blocks, and attaches the
    # lines to the Result as {Kills}. The verdict is the one a run without
    # `--matrix` gives (see {.finish}).
    #
    # @param timeout [Integer] timeout in seconds.
    # @param channel [Boolean] open a {KillChannel} pipe for the block.
    # @yieldparam channel [IO, nil] the pipe's write end, or nil without `channel`.
    # @yieldreturn [Integer] child exit status.
    # @return [Mutineer::Result] result from the child process.
    def self.run(timeout: DEFAULT_TIMEOUT, channel: false)
      rd, wr = IO.pipe if channel
      wr&.sync = true
      cause_rd, cause_wr = IO.pipe
      cause_wr.sync = true
      pid = fork do
        child = Process.pid
        rd&.close
        cause_rd.close
        # Own process group so a timeout kill can reap grandchildren (match
        # daemon/external backends). Best-effort: if setpgid fails, kill the pid.
        Process.setpgid(0, 0) rescue nil # rubocop:disable Style/RescueModifier
        code = 0
        begin
          ChildStdout.silence
          ChildCoverage.allow_start
          # A block that takes no channel (a zero-arity lambda) still runs.
          result = channel ? yield(wr) : yield
          code = result.is_a?(Integer) ? result : 0
        rescue SystemExit => e
          code = e.status
        rescue Exception => e # rubocop:disable Lint/RescueException
          # STDERR, not `warn`: a test may have left `$stderr` as a StringIO.
          STDERR.puts "[mutineer-child] #{Redaction.describe(e)}"
          ChildCause.write(cause_wr, e, child)
          code = 2
        end
        STDERR.flush
        # exit! skips at_exit handlers — critical, since a child forked from
        # inside our own Minitest suite would otherwise re-run the parent's
        # at_exit autorun hook on the way out.
        exit!(code)
      end

      wr&.close
      cause_wr.close
      buffer = +"" if rd
      reading = !rd.nil?

      # Single-threaded deadline poll: we are the ONLY caller of waitpid on this
      # pid, so we never reap-then-kill. SIGKILL the process group only after
      # WNOHANG shows the child is still alive past the deadline.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        reaped, status = Process.waitpid2(pid, Process::WNOHANG)
        return finish(decode(status, ChildCause.read(cause_rd)), rd, buffer, finished: true) if reaped

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          begin
            Process.kill(:KILL, -pid)
          rescue Errno::ESRCH, Errno::EPERM
            Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          end
          begin
            _reaped, status = Process.waitpid2(pid)
            # Child may have finished cleanly between WNOHANG and kill; honor it.
            return finish(decode(status, ChildCause.read(cause_rd)), rd, buffer, finished: true) if status && status.exited? && !status.signaled?
          rescue Errno::ECHILD
            # already reaped
          end
          return finish(Result.timeout, rd, buffer, finished: false)
        end
        if reading
          IO.select([rd], nil, nil, POLL_INTERVAL)
          reading = drain(rd, buffer)
        else
          sleep POLL_INTERVAL
        end
      end
    ensure
      rd&.close
      cause_rd&.close
      # Closed after the fork in the normal path; still open if fork raised.
      wr.close if wr && !wr.closed?
      cause_wr.close if cause_wr && !cause_wr.closed?
    end

    # Reads what the channel holds now, without blocking.
    #
    # @api private
    # @param rd [IO] the channel's read end.
    # @param buffer [String] bytes read so far; appended to.
    # @return [Boolean] false once the channel is at end of file.
    def self.drain(rd, buffer)
      loop do
        chunk = rd.read_nonblock(65_536, exception: false)
        return true if chunk == :wait_readable
        return false if chunk.nil?

        buffer << chunk
      end
    end

    # The Result to return. Without a channel it is `result` itself. With one,
    # the rest of the channel is read, and the Result carries the {Kills} it
    # names.
    #
    # The verdict matches a run without `--matrix`, which skips everything after
    # the first failing serial test except the code around it (see
    # {KillChannel}). So when a serial test has named a failure and the child then
    # ended inside a region that run would skip (an exit, a crash or the
    # timeout in a later test, class or group), its first failure decides:
    # `error` for an unavailable database outcome, otherwise `killed`. The
    # plain run never reached that point. An end anywhere else keeps the exit
    # status, because the plain run reaches that code too: the rest of the
    # failing test's class wrapper or group hooks, or the suite hooks. A kill in
    # the parallel tests of a Minitest run also keeps it, because the stop
    # cannot skip tests already queued.
    #
    # The row is complete only when the child ended before the timeout, sent a
    # valid stream with both `start` and `end`, lost no line, and its kills
    # agree with the verdict (a killed mutant names a killer; a survivor names
    # none). An invalid stream promotes nothing, and its tests are dropped: an
    # out-of-order line means the parent cannot tell which outcomes are real.
    #
    # @api private
    # @param result [Mutineer::Result] the verdict from the exit status or the timeout.
    # @param rd [IO, nil] the channel's read end.
    # @param buffer [String, nil] bytes read so far.
    # @param finished [Boolean] the child ended before the timeout.
    # @return [Mutineer::Result]
    def self.finish(result, rd, buffer, finished:)
      return result unless rd

      drain(rd, buffer)
      report = KillChannel.parse(buffer)
      return result.with(kills: Kills.new(killed_by: [], ran: [], complete: false)) if report.invalid

      result = Result.killed if report.started && report.serial_kill && report.skipping.positive?
      result = Result.error if report.started && report.serial_error && report.skipping.positive?
      agrees = result.killed? ? report.killed.any? : result.survived? && report.killed.empty?
      complete = finished && report.started && report.finished && report.lost.zero? && agrees
      result.with(kills: Kills.new(killed_by: report.killed, ran: report.ran, complete: complete))
    end

    # Strategy 7a (default): write the whole mutated file and `load` it, which
    # reopens its classes and redefines every method in place. Re-runs file-
    # level side effects. Child-only — mutates the loaded program.
    #
    # The tempfile is created in the ORIGINAL file's directory, not the system
    # temp dir, so any `require_relative` in the mutated source resolves
    # against its real neighbours (e.g. a mutator's `require_relative
    # "base"`). Writing it elsewhere makes those requires resolve to the temp
    # dir and raise LoadError.
    #
    # Loading the file reopens its namespace. With lazy loading, that can be the
    # first time Zeitwerk scans the namespace's directory. Zeitwerk skips hidden
    # files, so the leading dot keeps it from rejecting the tempfile's name as a
    # constant, in this child and in any other running at the same time (#253).
    #
    # A concern's stored `included` and `prepended` blocks from the source file
    # are forgotten around the load, so ActiveSupport accepts the blocks the
    # temp file stores (#256). For a def in such a block, the caller passes the
    # text and `hook_def` from {JobPlan.hook_mutant}, and the load places the
    # mutated def (#297, #348).
    #
    # {ConcernBlocks.load_mutant} turns Ruby's warnings off for the load, so
    # the constants it assigns again do not warn (#364).
    #
    # @api private
    # @param mutated [String] mutated source text.
    # @param source_file [String] original source file path.
    # @param hook_def [Hash{Symbol => Object}, nil] see {ConcernBlocks.load_mutant}.
    # @return [Object] whatever `load` returns.
    def self.apply_whole_file(mutated, source_file, hook_def: nil)
      write_beside(mutated, source_file) { |path| ConcernBlocks.load_mutant(source_file, path, hook_def: hook_def) }
    end

    # Writes `code` to a hidden `.mutineer_mutant` file beside `source_file`,
    # yields its path, and removes it after the block. Both strategies write
    # through here. Only redefine enables the system-temp fallback when the
    # source directory is not writable.
    #
    # The file is locked until the block ends, as the daemon locks its own file
    # (#295). A SIGKILL drops the lock too. The pid in the name and the lock
    # tell another run's sweep that the file is in use, so the sweep does not
    # delete it between the write and the `load`.
    #
    # @api private
    # @param code [String] the Ruby source to write.
    # @param source_file [String] the source file the code replaces.
    # @param fallback [Boolean] use the system temp directory when the source
    #   directory is not writable; redefine only.
    # @yieldparam path [String] absolute path of the written file.
    # @return [Object] whatever the block returns.
    def self.write_beside(code, source_file, fallback: false)
      dir = File.dirname(File.expand_path(source_file))
      dir = Dir.tmpdir if fallback && !File.writable?(dir)
      Tempfile.create([".mutineer_mutant", ".rb"], dir) do |f|
        f.flock(File::LOCK_EX) rescue nil # rubocop:disable Style/RescueModifier
        f.write(code)
        f.flush
        yield f.path
      end
    end

    # Redefine strategy: extract just the enclosing DefNode, apply the mutation
    # to that snippet, wrap it in its real namespace, and `load` only that one
    # method back into the running process. No file-level side effects re-run.
    # Child-only.
    #
    # The snippet keeps its own `def self.x` for singletons, so the namespace
    # wrapper redefines instance and singleton methods correctly without any
    # special-casing.
    #
    # @api private
    # @param mutation [Mutineer::Mutation] mutation to apply.
    # @param subject [Mutineer::Subject] subject being mutated.
    # @param source [String] full source text.
    # @return [Object] whatever `load` returns.
    def self.apply_surgical(mutation, subject, source)
      # Rebuild the FULL namespace nesting textually so unqualified enclosing-
      # namespace constants resolve exactly as the reload strategy would. A
      # bare redefinition on the owner would collapse Module.nesting to [owner]
      # and raise NameError on such constants (C2 scope-collapse).
      keywords = nesting_keywords(subject.lexical_namespace)
      prefix   = keywords.map { |kw, name| "#{kw} #{name}" }.join("\n")
      prefix  += "\n" unless prefix.empty?

      # #20: a singleton method whose def has NO `self.` receiver (the
      # `class << self` and `module_function` forms) would, as a bare `def foo`
      # inside `module Owner`, redefine the INSTANCE method — but the call
      # (`Owner.foo`) dispatches to the singleton, so the mutant never runs and
      # falsely survives. Re-open the singleton class so the redefinition lands on
      # the same method the test calls. `def self.foo` already carries its
      # receiver, so it is left as-is (wrapping it would mis-target).
      inner = mutated_def(mutation, subject, source)
      inner = "#{subject.block_owner}.class_eval do\n#{inner}\nend" if subject.block_owner
      wrapped = "#{prefix}#{inner}#{"\nend" * keywords.size}"

      # A snippet that fails to reparse must NOT silently fall through to
      # running the ORIGINAL method (C2 false-survived). Raise -> the fork
      # block aborts before any test runs -> Result.error, never a bogus
      # `survived`.
      raise "surgical snippet failed to reparse" if Parser.invalid?(wrapped)

      # Preserve original visibility — class/module bodies define methods
      # public, but 7a's `load` would re-apply the file's private/protected
      # (C2).
      owner  = subject.namespace.empty? ? Object : Object.const_get(subject.namespace.join("::"))
      target = subject.singleton ? owner.singleton_class : owner
      vis    = method_visibility(target, subject.name)

      # Write the wrapped snippet to a tempfile and `load` it: `load` runs it
      # at top level, so the textual class/module wrappers rebuild
      # Module.nesting identically, with no dynamic string execution for
      # scanners to flag. The input is the project's OWN source (the enclosing
      # method, textually mutated), loaded only in this forked child.
      #
      # The file sits beside the source, as in apply_whole_file (#279). A
      # read-only source directory keeps the 1.x system-temp location, so
      # redefine still runs there. Either file is a different path from the
      # source, so {anchor_paths} rewrites `__FILE__`, `__dir__`, and
      # `require_relative` to the original file before the load. Without that,
      # a temp-dir load raises ENOENT or LoadError and every mutant of the
      # method scores `killed` (#339). The hidden `.mutineer_mutant` name
      # keeps Zeitwerk away (#253) and lets the parent sweep an orphan after a
      # timeout kill.
      anchored = anchor_paths(wrapped, subject)
      # The anchored text is what `load` runs. A rewrite that does not reparse
      # must take the same error path as the unanchored snippet above.
      raise "surgical snippet failed to reparse" if anchored != wrapped && Parser.invalid?(anchored)

      write_beside(anchored, subject.file, fallback: true) { |path| load path }

      target.send(vis, subject.name) if vis && vis != :public
    end

    # Rewrites path anchors in a redefine snippet so they resolve against the
    # original source file when `load` runs a different file (#339).
    #
    # The hidden snippet is never the source file. Beside the source, `__dir__`
    # still names that directory, but `__FILE__` names the hidden file, and a
    # symlinked source makes `__dir__` and `require_relative` follow the link's
    # directory. In the system temp directory every one of them follows the
    # temp directory, so each mutant raises and scores `killed`. The rewrite
    # uses the live method's `source_location` when that file is `subject.file`,
    # so a symlink keeps the path the program loaded. `__dir__` and
    # `require_relative` use `File.realpath`, as Ruby does.
    #
    # Calls with an implicit receiver, literal `self`, or `Kernel` / `::Kernel`
    # are rewritten, including `send` and `__send__` whose name is a literal.
    # A call on any other receiver is left alone: `other.__dir__` is a private
    # call and raises.
    #
    # @api private
    # @param code [String] the wrapped snippet.
    # @param subject [Mutineer::Subject] the method being redefined.
    # @return [String] `code`, or a copy with the anchors rewritten.
    def self.anchor_paths(code, subject)
      return code unless code.match?(ANCHOR_PATTERN)

      file_path = anchor_file(subject)
      dir_literal = anchor_directory(file_path).dump
      PathAnchor.rewrite(code, file_path.dump, dir_literal)
    end

    # The path `__FILE__` must return for `subject`. The live method's
    # `source_location` wins when it is the same file, because that string is
    # the one the unmutated method returns (a symlink path stays a symlink
    # path). Otherwise the expanded subject path.
    #
    # @api private
    # @param subject [Mutineer::Subject] the method being redefined.
    # @return [String] absolute path.
    def self.anchor_file(subject)
      defined_in = defined_path(subject)
      return defined_in if defined_in && same_file?(defined_in, subject.file)

      File.expand_path(subject.file)
    end

    # The directory `__dir__` and `require_relative` use for `file_path`:
    # `File.dirname(File.realpath(file_path))`. A subject path that is not a
    # file yet (a unit probe) uses the real directory that contains it.
    #
    # @api private
    # @param file_path [String] the path {anchor_file} chose.
    # @return [String] absolute real directory.
    def self.anchor_directory(file_path)
      File.dirname(File.realpath(file_path))
    rescue SystemCallError
      File.realpath(File.dirname(File.expand_path(file_path)))
    end

    # The file the live method was defined in, when that method is `subject`'s
    # own. An inherited method, or a method that is not defined yet, returns nil
    # so {anchor_file} uses the subject path.
    #
    # @api private
    # @param subject [Mutineer::Subject] the method being redefined.
    # @return [String, nil] `source_location` path, or nil.
    def self.defined_path(subject)
      target = subject.namespace.empty? ? Object : Object.const_get(subject.namespace.join("::"))
      target = target.singleton_class if subject.singleton
      method = target.instance_method(subject.name)
      return unless method.owner == target

      method.source_location&.first
    rescue NameError
      nil
    end

    # Whether `left` and `right` are the same file after resolving symlinks.
    #
    # @api private
    # @param left [String] a path.
    # @param right [String] a path.
    # @return [Boolean]
    def self.same_file?(left, right)
      File.realpath(left) == File.realpath(right)
    rescue SystemCallError
      false
    end

    # The enclosing def with the mutation applied, wrapped in `class << self`
    # for a singleton def with no receiver (#20). Pure text: it reads no live
    # module, so the tool process can call it too ({JobPlan.hook_mutant}).
    #
    # @api private
    # @param mutation [Mutineer::Mutation] mutation to apply.
    # @param subject [Mutineer::Subject] subject being mutated.
    # @param source [String] full source text.
    # @return [String] the mutated def.
    def self.mutated_def(mutation, subject, source)
      loc = subject.def_node.location
      def_start = loc.start_offset
      snippet = source.byteslice(def_start...loc.end_offset)
      rel_s = mutation.start_offset - def_start
      rel_e = mutation.end_offset - def_start
      mutated = snippet.byteslice(0...rel_s) + mutation.replacement + snippet.byteslice(rel_e..)
      subject.singleton && subject.def_node.receiver.nil? ? "class << self\n#{mutated}\nend" : mutated
    end

    # Resolve each namespace ELEMENT to its live Module and pick the correct
    # keyword (reopening a class with `module` — or vice versa — raises
    # TypeError), so the textual wrapper matches the real definitions.
    #
    # #5: a compact element like "Foo::Bar" stays a SINGLE wrapper `class Foo::
    # Bar` (nesting [Foo::Bar]), matching how a whole-file load (reload) sees
    # it. Splitting it into `module Foo; class Bar` gave nesting [Foo::Bar,
    # Foo], so an unqualified constant defined only in Foo would resolve under
    # redefine but not reload — a strategy disagreement.
    #
    # A root-anchored element (`::Top`, #145) resolves from Object and keeps its
    # `::` in the wrapper, so `module Outer; class ::Top` rebuilds nesting
    # [Top, Outer] exactly as the source does.
    #
    # @api private
    # @param namespace [Array<String>] class/module chain as written.
    # @return [Array<[String, String]>] wrapper keywords and names.
    def self.nesting_keywords(namespace)
      mod = Object
      namespace.map do |name|
        # const_get resolves a compact "Foo::Bar" too
        mod = name.start_with?("::") ? Object.const_get(name.delete_prefix("::")) : mod.const_get(name)
        [mod.is_a?(Class) ? "class" : "module", name]
      end
    end

    # Returns the visibility for a method name.
    #
    # @api private
    # @param mod [Module] module or class being inspected.
    # @param name [Symbol] method name.
    # @return [Symbol, nil] `:public`, `:protected`, `:private`, or nil.
    def self.method_visibility(mod, name)
      return :private   if mod.private_method_defined?(name)
      return :protected if mod.protected_method_defined?(name)
      return :public    if mod.public_method_defined?(name)

      nil
    end

    # Decodes a child status into a Result.
    #
    # @api private
    # @param status [Process::Status] child exit status.
    # @param cause [String, nil] the {ChildCause} line the child sent, if any.
    # @return [Mutineer::Result] decoded result.
    def self.decode(status, cause = nil)
      case status.exitstatus
      when 0 then Result.survived
      when 1 then Result.killed
      when 2 then Result.error(cause || "child exited with status 2")
      else        Result.error("unexpected exit status: #{status.exitstatus.inspect}")
      end
    end

    # Rewrites path anchors in one snippet (#339). A `require_relative` argument
    # is rewritten on its own first, so a nested `__dir__` or `__FILE__` is not
    # left pointing at the file `load` runs.
    #
    # @api private
    class PathAnchor < Prism::Visitor
      # Argument nodes that are not a single expression to splice into
      # `File.expand_path`. A splat or a keyword would change meaning there.
      SKIPPED_ARGUMENTS = [
        Prism::SplatNode, Prism::KeywordHashNode, Prism::BlockArgumentNode, Prism::ForwardingArgumentsNode
      ].freeze

      # @param source [String] the snippet or argument to rewrite.
      # @param file_literal [String] a dumped Ruby string of the original `__FILE__`.
      # @param dir_literal [String] a dumped Ruby string of the original `__dir__`.
      def initialize(source, file_literal, dir_literal)
        @source = source
        @file_literal = file_literal
        @dir_literal = dir_literal
        @edits = []
      end

      # Parses `source` and applies the edits. Parse errors return `source`
      # unchanged: the caller's reparse guard then scores the snippet `error`.
      #
      # @param source [String] snippet or argument source.
      # @param file_literal [String] dumped original `__FILE__`.
      # @param dir_literal [String] dumped original `__dir__`.
      # @return [String]
      def self.rewrite(source, file_literal, dir_literal)
        parsed = Prism.parse(source)
        return source unless parsed.errors.empty?

        anchor = new(source, file_literal, dir_literal)
        anchor.visit(parsed.value)
        anchor.apply
      end

      # Replaces a `__FILE__` keyword with the original path.
      #
      # @param node [Prism::SourceFileNode] the keyword.
      # @return [void]
      def visit_source_file_node(node)
        replace(node, @file_literal)
      end

      # Replaces a path-anchor call, or walks into a call that is not one.
      #
      # @param node [Prism::CallNode] a call in the snippet.
      # @return [void]
      def visit_call_node(node)
        return replace(node, @dir_literal) if dir_call?(node)

        if (argument = relative_argument(node))
          anchored = self.class.rewrite(slice(argument), @file_literal, @dir_literal)
          text = ["require(File.expand_path(", anchored, ", ", @dir_literal, "))"].join
          return replace(node, text)
        end

        super
      end

      # Applies recorded edits from the end, so earlier byte offsets stay valid.
      #
      # @return [String] the rewritten source.
      def apply
        @edits.sort_by! { |start_off,| -start_off }
        @edits.inject(@source) do |code, (start_off, end_off, text)|
          code.byteslice(0, start_off) + text + code.byteslice(end_off..)
        end
      end

      private

      # True when `node` is the `__dir__` keyword, including `self.__dir__`,
      # `Kernel.__dir__`, and `send` / `__send__` of the literal name.
      #
      # @param node [Prism::CallNode]
      # @return [Boolean]
      def dir_call?(node)
        return false if node.block

        args = positional(node)
        return false if args.nil?

        if node.name == :__dir__
          path_receiver?(node) && args.empty?
        elsif send_call?(node)
          args.size == 1 && literal_name(args.first) == "__dir__"
        else
          false
        end
      end

      # The single path argument of a `require_relative` call, or nil when the
      # call is not that anchor. `send(:require_relative, expr)` returns `expr`.
      #
      # @param node [Prism::CallNode]
      # @return [Prism::Node, nil]
      def relative_argument(node)
        return if node.block

        args = positional(node)
        return unless args

        if node.name == :require_relative && path_receiver?(node) && args.size == 1
          args.first
        elsif send_call?(node) && args.size == 2 && literal_name(args.first) == "require_relative"
          args.last
        end
      end

      # True for an implicit receiver, literal `self`, or `Kernel` / `::Kernel`.
      #
      # @param node [Prism::CallNode]
      # @return [Boolean]
      def path_receiver?(node)
        receiver = node.receiver
        return true if receiver.nil? || receiver.is_a?(Prism::SelfNode)

        kernel_constant?(receiver)
      end

      # True when `node` is `Kernel` or `::Kernel`.
      #
      # @param node [Prism::Node]
      # @return [Boolean]
      def kernel_constant?(node)
        (node.is_a?(Prism::ConstantReadNode) && node.name == :Kernel) ||
          (node.is_a?(Prism::ConstantPathNode) && node.parent.nil? && node.name == :Kernel)
      end

      # True for `send` or `__send__` on a receiver {path_receiver?} accepts.
      #
      # @param node [Prism::CallNode]
      # @return [Boolean]
      def send_call?(node)
        (node.name == :send || node.name == :__send__) && path_receiver?(node)
      end

      # Positional arguments, or nil when one of them is a splat or keywords.
      #
      # @param node [Prism::CallNode]
      # @return [Array<Prism::Node>, nil]
      def positional(node)
        args = node.arguments&.arguments || []
        return if args.any? { |arg| SKIPPED_ARGUMENTS.any? { |kind| arg.is_a?(kind) } }

        args
      end

      # The text of a symbol or string literal, without quotes.
      #
      # @param node [Prism::Node]
      # @return [String, nil]
      def literal_name(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end

      # The snippet bytes of `node`.
      #
      # @param node [Prism::Node]
      # @return [String]
      def slice(node)
        location = node.location
        @source.byteslice(location.start_offset, location.end_offset - location.start_offset)
      end

      # Records a replacement of `node`'s source range.
      #
      # @param node [Prism::Node]
      # @param text [String] the Ruby source to write instead.
      # @return [void]
      def replace(node, text)
        location = node.location
        @edits << [location.start_offset, location.end_offset, text]
      end
    end
    private_constant :PathAnchor
  end
end
