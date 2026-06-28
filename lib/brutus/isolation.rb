# frozen_string_literal: true

require "tempfile"
require_relative "result"
require_relative "parser"

module Brutus
  # Fork-based isolation for running one mutant. The block runs in a child
  # process; the parent enforces a wall-clock timeout and decodes the child's
  # exit status into a Result.
  #
  # Exit-status contract (the block's return value, or an explicit exit, is the
  # child's status): 0 => survived, 1 => killed, 2 => error. Timeout is detected
  # by the parent's monitor flag, not by status.signaled? (which is true for ANY
  # signal death, e.g. SIGSEGV — it cannot tell our SIGKILL apart from the OS's).
  #
  # brutus: the 7a strategy this enables (whole-file `load`) re-executes the
  # entire file — any top-level code runs again. Acceptable for POROs; document
  # if users hit issues with initializers/callbacks. Upgrade path: M5 strategy
  # 7b (class_eval surgical redefinition).
  class Isolation
    DEFAULT_TIMEOUT = 10 # seconds

    # Runs the block in a forked child. The block's return value (an Integer
    # exit code) or any explicit `exit` is honoured; an unhandled exception
    # becomes exit 2 with the cause written to STDERR.
    def self.run(timeout: DEFAULT_TIMEOUT)
      timed_out = false
      pid = fork do
        code = 0
        begin
          result = yield
          code = result.is_a?(Integer) ? result : 0
        rescue SystemExit => e
          code = e.status
        rescue Exception => e # rubocop:disable Lint/RescueException
          warn "[brutus-child] #{e.class}: #{e.message}"
          code = 2
        end
        $stderr.flush
        # exit! skips at_exit handlers — critical, since a child forked from
        # inside our own Minitest suite would otherwise re-run the parent's
        # at_exit autorun hook on the way out.
        exit!(code)
      end

      monitor = Thread.new do
        sleep timeout
        timed_out = true
        Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
      end

      _, status = Process.wait2(pid)
      monitor.kill
      decode(status, timed_out: timed_out)
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
      Tempfile.create(["brutus_mutant", ".rb"], File.dirname(source_file)) do |f|
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
      snippet = source[def_start...loc.end_offset]
      rel_s = mutation.start_offset - def_start
      rel_e = mutation.end_offset - def_start
      mutated = snippet[0...rel_s] + mutation.replacement + snippet[rel_e..]
      return if Parser.parse_string(mutated).errors.any? # parent guard already filters

      owner = subject.namespace.empty? ? Object : Object.const_get(subject.namespace.join("::"))
      def_line = source[0...def_start].count("\n") + 1
      owner.class_eval(mutated, subject.file, def_line)
    end

    def self.decode(status, timed_out:)
      return Result.timeout if timed_out

      case status.exitstatus
      when 0 then Result.survived
      when 1 then Result.killed
      when 2 then Result.error("child exited with status 2")
      else        Result.error("unexpected exit status: #{status.exitstatus.inspect}")
      end
    end
  end
end
