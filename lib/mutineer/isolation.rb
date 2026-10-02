# frozen_string_literal: true

require "tempfile"
require_relative "result"
require_relative "parser"
require_relative "child_stdout"
require_relative "kill_channel"

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

    # Runs the block in a forked child. The block's return value (an Integer
    # exit code) or any explicit `exit` is honoured; an unhandled exception
    # becomes exit 2 with the cause written to STDERR.
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
      pid = fork do
        rd&.close
        # Own process group so a timeout kill can reap grandchildren (match
        # daemon/external backends). Best-effort: if setpgid fails, kill the pid.
        Process.setpgid(0, 0) rescue nil # rubocop:disable Style/RescueModifier
        code = 0
        begin
          ChildStdout.silence
          result = yield(wr)
          code = result.is_a?(Integer) ? result : 0
        rescue SystemExit => e
          code = e.status
        rescue Exception => e # rubocop:disable Lint/RescueException
          # STDERR, not `warn`: a test may have left `$stderr` as a StringIO.
          STDERR.puts "[mutineer-child] #{e.class}: #{e.message}"
          code = 2
        end
        STDERR.flush
        # exit! skips at_exit handlers — critical, since a child forked from
        # inside our own Minitest suite would otherwise re-run the parent's
        # at_exit autorun hook on the way out.
        exit!(code)
      end

      wr&.close
      buffer = +"" if rd
      reading = !rd.nil?

      # Single-threaded deadline poll: we are the ONLY caller of waitpid on this
      # pid, so we never reap-then-kill. SIGKILL the process group only after
      # WNOHANG shows the child is still alive past the deadline.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        reaped, status = Process.waitpid2(pid, Process::WNOHANG)
        return finish(decode(status), rd, buffer, finished: true) if reaped

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          begin
            Process.kill(:KILL, -pid)
          rescue Errno::ESRCH, Errno::EPERM
            Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          end
          begin
            _reaped, status = Process.waitpid2(pid)
            # Child may have finished cleanly between WNOHANG and kill; honor it.
            return finish(decode(status), rd, buffer, finished: true) if status && status.exited? && !status.signaled?
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
    # The verdict matches a run without `--matrix`, which stops at the first
    # failing test and exits `killed` there. So once a serial run has named a
    # kill, the mutant is `killed`, whatever a later test does: exit the
    # process, crash, or run into the timeout. A parallel run (see
    # {KillChannel}) keeps the exit status, because the stop cannot skip its
    # queued tests either.
    #
    # The row is complete only when the child ended before the timeout, sent
    # both `start` and `end`, lost no line, and its kills agree with the
    # verdict (a killed mutant names a killer; a survivor names none).
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
      result = Result.killed if report.started && !report.parallel && report.killed.any?
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
    # @api private
    # @param mutated [String] mutated source text.
    # @param source_file [String] original source file path.
    # @return [Object] whatever `load` returns.
    def self.apply_whole_file(mutated, source_file)
      Tempfile.create(["mutineer_mutant", ".rb"], File.dirname(File.expand_path(source_file))) do |f|
        f.write(mutated)
        f.flush
        load f.path
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
      loc = subject.def_node.location
      def_start = loc.start_offset
      snippet = source.byteslice(def_start...loc.end_offset)
      rel_s = mutation.start_offset - def_start
      rel_e = mutation.end_offset - def_start
      mutated_def = snippet.byteslice(0...rel_s) + mutation.replacement + snippet.byteslice(rel_e..)

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
      inner =
        if subject.singleton && subject.def_node.receiver.nil?
          "class << self\n#{mutated_def}\nend"
        else
          mutated_def
        end
      wrapped = "#{prefix}#{inner}#{"\nend" * keywords.size}"

      # A snippet that fails to reparse must NOT silently fall through to
      # running the ORIGINAL method (C2 false-survived). Raise -> the fork
      # block aborts before any test runs -> Result.error, never a bogus
      # `survived`.
      raise "surgical snippet failed to reparse" if Parser.parse_string(wrapped).errors.any?

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
      Tempfile.create(["mutineer_surgical", ".rb"]) do |f|
        f.write(wrapped)
        f.flush
        load f.path
      end

      target.send(vis, subject.name) if vis && vis != :public
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
    # @return [Mutineer::Result] decoded result.
    def self.decode(status)
      case status.exitstatus
      when 0 then Result.survived
      when 1 then Result.killed
      when 2 then Result.error("child exited with status 2")
      else        Result.error("unexpected exit status: #{status.exitstatus.inspect}")
      end
    end
  end
end
