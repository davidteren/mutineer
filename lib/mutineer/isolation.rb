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

    # Runs the block in a forked child. The block's return value (an Integer
    # exit code) or any explicit `exit` is honoured; an unhandled exception
    # becomes exit 2 with the cause written to STDERR.
    #
    # @param timeout [Integer] timeout in seconds.
    # @yieldreturn [Integer] child exit status.
    # @return [Mutineer::Result] result from the child process.
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

      # Single-threaded deadline poll (R2): we are the ONLY caller of waitpid
      # on this pid, so we never reap-then-kill. We SIGKILL only after WNOHANG
      # shows the child is still alive past the deadline — so the kill can
      # never hit a reaped/recycled pid. Timeout is a parent-side fact
      # (deadline reached), not status.signaled? (which is true for ANY signal
      # death, e.g. SIGSEGV).
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
      Tempfile.create(["mutineer_mutant", ".rb"], File.dirname(source_file)) do |f|
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
      keywords = nesting_keywords(subject.namespace)
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
    # @api private
    # @param namespace [Array<String>] namespace components.
    # @return [Array<[String, String]>] wrapper keywords and names.
    def self.nesting_keywords(namespace)
      mod = Object
      namespace.map do |name|
        mod = mod.const_get(name) # const_get resolves a compact "Foo::Bar" too
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
