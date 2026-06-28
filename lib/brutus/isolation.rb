# frozen_string_literal: true

require_relative "result"

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
