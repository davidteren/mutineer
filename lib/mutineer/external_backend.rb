# frozen_string_literal: true

require "shellwords"
require "tempfile"
require_relative "result"

module Mutineer
  # Raised when the smoke check (the unmutated suite) is not green, so the run
  # aborts before scoring — a broken environment must never be reported as strong
  # tests. The CLI maps this to a runtime error (exit 1), not a usage error.
  class SmokeCheckError < StandardError; end

  # External execution backend. Runs the user's `--test-command` as a subprocess
  # in the app's own runtime (whatever Ruby its bundle resolves to), so mutineer
  # (Ruby ≥ 3.4) can mutation-test apps pinned to an older Ruby.
  #
  # This is deliberately NOT a `TestRunners` framework adapter: those return an
  # Integer 0/1 from inside a fork and are dispatched by framework name. This is a
  # whole backend — it spawns a process, enforces a wall-clock timeout, and maps
  # the exit status to a Result. The mapping is the same direction as in-process
  # (suite passes => survived, suite fails => killed) but coarser: it cannot tell an
  # infrastructure error from a genuine kill, so the smoke check (below) guards the
  # persistent case and the score is disclosed as an upper bound.
  #
  # Child environment: bundler/gem env injected by Mutineer's Ruby is stripped, and
  # version-manager concrete version bins (e.g. `~/.rbenv/versions/3.4.9/bin`) are
  # removed from PATH so shims / `.ruby-version` can select the app's Ruby (#32).
  module ExternalBackend
    # Generous ceiling for the one-off smoke/calibration run (a cold app boot plus
    # the full suite). The per-mutant timeout is derived from how long this took.
    SMOKE_TIMEOUT = 900
    # Poll interval for the deadline wait loop. Independent of Isolation's loop —
    # this backend waits on an external process TREE, not an in-process fork.
    POLL = 0.02

    # PATH entries that pin a concrete Ruby under a version manager (ahead of
    # shims). Optional trailing slash; normal bins are left alone.
    VERSION_BIN_PATH = %r{
      (?:
        /\.rbenv/versions/[^/]+/bin
        |/\.asdf/installs/ruby/[^/]+/bin
        |/\.rubies/[^/]+/bin
        |/rubies/[^/]+/bin
      )/?\z
    }x

    # Env keys Process.spawn must unset (nil value) so Mutineer's Ruby/bundler
    # context does not leak. Spawn merges env onto the parent; omitting a key
    # does NOT clear it.
    CLEAR_ENV_KEYS = %w[
      BUNDLER_VERSION RBENV_VERSION ASDF_RUBY_VERSION RBENV_DIR
    ].freeze

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

    # Environment delta for the test-command child. Process.spawn merges this
    # onto the parent env: set a key to +nil+ to unset it. Scrubs Mutineer/bundler
    # injection and version-manager PATH pins so shims / `.ruby-version` can win.
    # Keeps other vars (e.g. `RAILS_ENV`) so setting them on the Mutineer command
    # still reaches the suite.
    #
    # @api private
    # @return [Hash{String => String, nil}] env for Process.spawn.
    def self.child_env
      env = {}
      cleared_pin = false
      ENV.each_key do |k|
        next unless clear_env_key?(k)

        env[k] = nil
        cleared_pin = true
      end
      path = ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
      kept = path.reject { |p| p.match?(VERSION_BIN_PATH) }
      scrubbed_bin = kept.size != path.size
      # Only reorder PATH when we scrubbed a pin; otherwise leave the user's PATH alone.
      path = if cleared_pin || scrubbed_bin
               (version_manager_shim_dirs + kept).uniq
             else
               kept
             end
      env["PATH"] = path.join(File::PATH_SEPARATOR)
      env
    end

    # True when the key must be unset in the child (bundler/gem/version-manager).
    #
    # @api private
    # @param key [String] environment variable name.
    # @return [Boolean]
    def self.clear_env_key?(key)
      key.start_with?("BUNDLE_", "RUBY", "GEM_") || CLEAR_ENV_KEYS.include?(key)
    end

    # Existing shim directories for rbenv / asdf (chruby uses PATH without shims).
    #
    # @api private
    # @return [Array<String>] absolute shim paths that exist.
    def self.version_manager_shim_dirs
      home = ENV["HOME"]
      return [] if home.nil? || home.empty?

      [
        File.join(home, ".rbenv", "shims"),
        File.join(home, ".asdf", "shims")
      ].select { |d| File.directory?(d) }
    end

    # Runs the command for ONE mutant against whatever is currently on disk (the
    # caller has already swapped the mutant in via FileSwap). Maps the outcome to a
    # Result. Uses {child_env} so version-manager PATH pins from Mutineer's Ruby do
    # not force the suite onto the wrong interpreter.
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
        # Signal death (nil exitstatus) is infrastructure, not a suite assertion
        # failure — match Isolation/daemon (error), do not inflate kill rate.
        if code.nil?
          warn output if verbose && !output.empty?
          return Result.error("test-command terminated by signal")
        end

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

      reason =
        if kind == :timeout then "did not finish within #{timeout}s"
        elsif code.nil?      then "was terminated by a signal"
        else                      "exited #{code}"
        end
      detail = output.empty? ? "" : "\n--- last output ---\n#{tail(output)}"
      hint = ruby_version_mismatch_hint(output)
      raise SmokeCheckError,
            "the test command #{reason} against the UNMUTATED source — " \
            "#{hint || generic_env_hint}.#{detail}"
    end

    # Generic smoke-failure framing when no Ruby-version mismatch is detected.
    #
    # @api private
    # @return [String]
    def self.generic_env_hint
      "the unmutated suite is not green (failing tests, or a broken environment: " \
        "DB, RAILS_ENV, migrations) — fix that before scoring"
    end

    # Targeted hint when Bundler reports a RubyVersionMismatch (common under
    # rbenv/asdf/chruby when Mutineer's version bin sits ahead of shims on PATH).
    #
    # @api private
    # @param output [String] captured child stdout+stderr.
    # @return [String, nil] hint text, or nil when not a version mismatch.
    def self.ruby_version_mismatch_hint(output)
      return nil if output.nil? || output.empty?
      return nil unless output.match?(/RubyVersionMismatch|Your Ruby version is .* but your Gemfile specified/i)

      ran = output[/Your Ruby version is ([0-9.]+)/i, 1]
      want = output[/Gemfile specified ([0-9.]+)/i, 1]
      parts = +"Detected a Ruby version mismatch"
      parts << ": the test command ran under #{ran}" if ran
      parts << " but the app expects #{want}" if want
      parts << ". Mutineer already scrubbed version-manager bins and RBENV_VERSION/" \
               "ASDF_RUBY_VERSION from the child env; the suite still picked the wrong " \
               "Ruby. Use a wrapper that re-selects the app Ruby and ensure " \
               ".ruby-version / .tool-versions is present " \
               "(see README: Apps on Ruby < 3.4 → Under a version manager)"
      parts
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
      # Unreachable in practice (validate_test_command! guarantees a non-empty
      # command with %{files}); a neutral ArgumentError, not the smoke-specific
      # SmokeCheckError, since this is not a smoke-check failure.
      raise ArgumentError, "--test-command produced an empty command" if argv.empty?

      out = Tempfile.create("mutineer_ext")
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # `pgroup: true` puts the child in its OWN process group so a timeout can
      # kill the whole tree (`bundle exec rails test` forks parallel workers;
      # spring/bundler add more) — killing only the leader would orphan workers
      # that keep holding the shared DB, corrupting later serial mutants. The
      # explicit [program, argv0] form guarantees the no-shell exec path even for a
      # degenerate single-element argv (Process.spawn(*argv) would route a lone
      # metachar-bearing string through /bin/sh, breaking the argv-only invariant).
      pid = Process.spawn(child_env, [argv.first, argv.first], *argv[1..],
                          out: out, err: %i[child out], pgroup: true)
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

    # Waits for the spawned pid, SIGKILLing its process group past the deadline.
    # Single-waiter deadline loop (mirrors Isolation), so the kill can never hit a
    # reaped/recycled pid.
    #
    # @api private
    # @param pid [Integer] the spawned child pid.
    # @param timeout [Numeric] wall-clock deadline in seconds.
    # @return [Array(Symbol, Integer, nil)] `[:exited, code]` or `[:timeout, nil]`.
    def self.wait_with_timeout(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        reaped, status = Process.waitpid2(pid, Process::WNOHANG)
        return [:exited, status.exitstatus] if reaped

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          # Kill the whole process GROUP (negative pid) so forked test workers die
          # with the leader; fall back to the leader alone if the group is already
          # gone. The child led its group (pgroup: true at spawn).
          begin
            Process.kill(:KILL, -pid)
          rescue Errno::ESRCH, Errno::EPERM
            Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          end
          begin
            _reaped, status = Process.waitpid2(pid)
            # Finished cleanly between poll and kill — honor real exit code.
            return [:exited, status.exitstatus] if status && status.exited? && !status.signaled?
          rescue Errno::ECHILD
            # already reaped
          end
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
