# frozen_string_literal: true

require "tempfile"
require_relative "result"
require_relative "parser"

module Mutineer
  # Fork-based isolation for running one mutant. The block runs in a child
  # process; the parent enforces a wall-clock timeout and decodes the child's
  # exit status into a Result.
  #
  # Exit-status contract (the block's return value, or an explicit exit, is the
  # child's status): 0 => survived, 1 => killed, 2 => error. Timeout is detected
  # by the parent's monitor flag, not by status.signaled? (which is true for ANY
  # signal death, e.g. SIGSEGV — it cannot tell our SIGKILL apart from the OS's).
  #
  # mutineer: the 7a strategy this enables (whole-file `load`) re-executes the
  # entire file — any top-level code runs again. Acceptable for POROs; document
  # if users hit issues with initializers/callbacks. Upgrade path: M5 strategy
  # 7b (class_eval surgical redefinition).
  class Isolation
    DEFAULT_TIMEOUT = 10 # seconds

    # Runs the block in a forked child. The block's return value (an Integer
    # exit code) or any explicit `exit` is honoured; an unhandled exception
    # becomes exit 2 with the cause written to STDERR.
    def self.run(timeout: DEFAULT_TIMEOUT)
      pid = fork do
        code = 0
        begin
          result = yield
          code = result.is_a?(Integer) ? result : 0
        rescue SystemExit => e
          code = e.status
        rescue Exception => e # rubocop:disable Lint/RescueException
          warn "[mutineer-child] #{e.class}: #{e.message}"
          code = 2
        end
        $stderr.flush
        # exit! skips at_exit handlers — critical, since a child forked from
        # inside our own Minitest suite would otherwise re-run the parent's
        # at_exit autorun hook on the way out.
        exit!(code)
      end

      # Single-threaded deadline poll (R2): we are the ONLY caller of waitpid on
      # this pid, so we never reap-then-kill. We SIGKILL only after WNOHANG shows
      # the child is still alive past the deadline — so the kill can never hit a
      # reaped/recycled pid. Timeout is a parent-side fact (deadline reached), not
      # status.signaled? (which is true for ANY signal death, e.g. SIGSEGV).
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        reaped, status = Process.waitpid2(pid, Process::WNOHANG)
        return decode(status) if reaped

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          Process.waitpid(pid) rescue nil # rubocop:disable Style/RescueModifier
          return Result.timeout
        end
        sleep 0.005
      end
    end

    # Strategy 7a (default): write the whole mutated file and `load` it, which
    # reopens its classes and redefines every method in place. Re-runs file-level
    # side effects. Child-only — mutates the loaded program.
    #
    # The tempfile is created in the ORIGINAL file's directory, not the system
    # temp dir, so any `require_relative` in the mutated source resolves against
    # its real neighbours (e.g. a mutator's `require_relative "base"`). Writing it
    # elsewhere makes those requires resolve to the temp dir and raise LoadError.
    def self.apply_whole_file(mutated, source_file)
      Tempfile.create(["mutineer_mutant", ".rb"], File.dirname(source_file)) do |f|
        f.write(mutated)
        f.flush
        load f.path
      end
    end

    # Strategy 7b: extract just the enclosing DefNode, apply the mutation to that
    # snippet, resolve the owner via the namespace path, and class_eval the one
    # method (KTD6). No file-level side effects re-run. Child-only.
    #
    # ponytail: a single owner.class_eval handles BOTH instance and singleton
    # methods — the extracted snippet keeps its own `def self.x` for singletons,
    # so class_eval (self == owner) redefines it correctly. Routing singletons
    # through singleton_class.class_eval (R17) would double-wrap and define on the
    # wrong class.
    def self.apply_surgical(mutation, subject, source)
      loc = subject.def_node.location
      def_start = loc.start_offset
      # Byte slicing (C1): Prism offsets are byte offsets.
      snippet = source.byteslice(def_start...loc.end_offset)
      rel_s = mutation.start_offset - def_start
      rel_e = mutation.end_offset - def_start
      mutated_def = snippet.byteslice(0...rel_s) + mutation.replacement + snippet.byteslice(rel_e..)

      # Rebuild the FULL namespace nesting textually so unqualified enclosing-
      # namespace constants resolve exactly as a whole-file `load` (7a) would.
      # class_eval(string) would collapse Module.nesting to [owner] and raise
      # NameError on such constants (C2 scope-collapse).
      keywords = nesting_keywords(subject.namespace)
      prefix   = keywords.map { |kw, name| "#{kw} #{name}" }.join("\n")
      prefix  += "\n" unless prefix.empty?
      wrapped  = "#{prefix}#{mutated_def}#{"\nend" * keywords.size}"

      # A snippet that fails to reparse must NOT silently fall through to running
      # the ORIGINAL method (C2 false-survived). Raise -> the fork block aborts
      # before any test runs -> Result.error, never a bogus `survived`.
      raise "surgical snippet failed to reparse" if Parser.parse_string(wrapped).errors.any?

      # Preserve original visibility — class/module bodies define methods public,
      # but 7a's `load` would re-apply the file's private/protected (C2).
      owner  = subject.namespace.empty? ? Object : Object.const_get(subject.namespace.join("::"))
      target = subject.singleton ? owner.singleton_class : owner
      vis    = method_visibility(target, subject.name)

      # Byte-correct line number; eval at top level so the textual class/module
      # wrappers rebuild Module.nesting. Offset the lineno by the wrapper prefix
      # so the def lands on its real source line.
      def_line = source.byteslice(0, def_start).count("\n") + 1
      eval_line = [def_line - prefix.count("\n"), 1].max
      eval(wrapped, TOPLEVEL_BINDING, subject.file, eval_line) # rubocop:disable Security/Eval

      target.send(vis, subject.name) if vis && vis != :public
    end

    # Resolve each segment of the namespace to its live Module and pick the
    # correct keyword (reopening a class with `module` — or vice versa — raises
    # TypeError), so the textual wrapper matches the real definitions.
    def self.nesting_keywords(namespace)
      mod = Object
      namespace.flat_map { |n| n.split("::") }.map do |name|
        mod = mod.const_get(name)
        [mod.is_a?(Class) ? "class" : "module", name]
      end
    end

    def self.method_visibility(mod, name)
      return :private   if mod.private_method_defined?(name)
      return :protected if mod.protected_method_defined?(name)
      return :public    if mod.public_method_defined?(name)

      nil
    end

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
