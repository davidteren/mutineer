# frozen_string_literal: true

require "shellwords"
require "tempfile"
require_relative "result"

module Mutineer
  # Raised when the smoke check (the unmutated suite) is not green, so the run
  # aborts before scoring — a broken environment must never be reported as strong
  # tests. The CLI maps this to a runtime error (exit 1), not a usage error.
  class SmokeCheckError < StandardError; end

  # #27 (U3): the external execution backend. Runs the user's `--test-command` as a
  # subprocess in the app's OWN runtime (whatever Ruby its bundle resolves to), so
  # mutineer (Ruby >= 3.4) can mutation-test apps pinned to an older Ruby.
  #
  # This is deliberately NOT a `TestRunners` framework adapter: those return an
  # Integer 0/1 from inside a fork and are dispatched by framework name. This is a
  # whole backend — it spawns a process, enforces a wall-clock timeout, and maps
  # the exit status to a Result. The mapping is the SAME direction as in-process
  # (suite passes => survived, suite fails => killed) but coarser: it cannot tell an
  # infrastructure error from a genuine kill, so the smoke check (below) guards the
  # persistent case and the score is disclosed as an upper bound (KTD-3/KTD-6).
  module ExternalBackend
    # Generous ceiling for the one-off smoke/calibration run (a cold app boot plus
    # the full suite). The per-mutant timeout is derived from how long this took.
    SMOKE_TIMEOUT = 900
    # Poll interval for the wait loop (matches Isolation).
    POLL = 0.02

    # Turn a command template into an argv array (no shell → no eval, no
    # injection). The `%{files}` token expands IN PLACE to N separate argv
    # elements — one per path, unescaped — so a path containing a space stays a
    # single argument. It is not a space-joined string.
    #
    # @param command [String] the --test-command template (contains %{files}).
    # @param files [Array<String>] test file paths to substitute.
    # @return [Array<String>] argv.
    def self.build_argv(command, files)
      Shellwords.split(command).flat_map { |tok| tok == "%{files}" ? files : [tok] }
    end

    # Runs the command for ONE mutant against whatever is currently on disk (the
    # caller has already swapped the mutant in via FileSwap). Maps the outcome to a
    # Result. Env is inherited by the subprocess, so `RAILS_ENV=test mutineer …`
    # reaches the child with no parsing here.
    #
    # @param command [String] the --test-command template.
    # @param files [Array<String>] test file paths.
    # @param timeout [Numeric] per-mutant wall-clock timeout in seconds.
    # @param verbose [Boolean] print the child's captured output on a non-pass.
    # @return [Mutineer::Result]
    def self.run(command, files, timeout:, verbose: false)
      kind, code, output, = spawn_capture(command, files, timeout)
      case kind
      when :timeout
        # A timeout is the one non-pass we flag by default — a normal kill is also
        # a non-zero exit, so notifying on every non-zero would spam every kill.
        warn "[mutineer] test-command exceeded #{timeout}s and was killed (scored timeout)."
        warn output if verbose && !output.empty?
        Result.timeout
      else # :exited
        return Result.survived if code&.zero?

        warn output if verbose && !output.empty?
        Result.killed
      end
    end

    # Pre-flight: run the command once against the UNMUTATED tree. Green (exit 0)
    # returns the elapsed seconds (used to calibrate the per-mutant timeout);
    # anything else raises SmokeCheckError so the run aborts before scoring.
    #
    # @param command [String] the --test-command template.
    # @param files [Array<String>] test file paths.
    # @param timeout [Numeric] ceiling for the calibration run.
    # @return [Float] elapsed seconds of the clean run.
    # @raise [Mutineer::SmokeCheckError] when the clean suite is not green.
    def self.smoke_check!(command, files, timeout: SMOKE_TIMEOUT)
      kind, code, output, elapsed = spawn_capture(command, files, timeout)
      return elapsed if kind == :exited && code&.zero?

      reason = kind == :timeout ? "did not finish within #{timeout}s" : "exited #{code}"
      detail = output.empty? ? "" : "\n--- last output ---\n#{tail(output)}"
      raise SmokeCheckError,
            "the test command #{reason} against the UNMUTATED source — the " \
            "environment looks broken (check DB, RAILS_ENV, migrations), not the " \
            "tests weak.#{detail}"
    end

    # Spawns the command to a captured combined-output tempfile, enforces a
    # wall-clock timeout (SIGKILL past the deadline), and returns
    # [kind, exit_code, output, elapsed]. Mirrors Isolation's single-waiter loop:
    # we are the only caller of waitpid on this pid, so the kill can never hit a
    # reaped/recycled pid.
    #
    # @api private
    def self.spawn_capture(command, files, timeout)
      argv = build_argv(command, files)
      raise SmokeCheckError, "--test-command produced an empty command" if argv.empty?

      out = Tempfile.create("mutineer_ext")
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pid = Process.spawn(*argv, out: out, err: %i[child out])
      kind, code = wait_with_timeout(pid, timeout)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      out.rewind
      [kind, code, out.read, elapsed]
    ensure
      if out
        out.close
        File.unlink(out.path) rescue nil # rubocop:disable Style/RescueModifier
      end
    end

    # @api private
    def self.wait_with_timeout(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        reaped, status = Process.waitpid2(pid, Process::WNOHANG)
        return [:exited, status.exitstatus] if reaped

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          Process.waitpid(pid) rescue nil # rubocop:disable Style/RescueModifier
          return [:timeout, nil]
        end
        sleep POLL
      end
    end

    # Last ~40 lines of captured output, for a smoke-failure message.
    #
    # @api private
    def self.tail(output, lines = 40)
      output.lines.last(lines).join
    end
  end
end
