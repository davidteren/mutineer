# frozen_string_literal: true

require "json"
require "open3"
require_relative "external_backend"

module Mutineer
  # Raised when the daemon cannot be booted or is gone for good: a bad boot path, an
  # app error, a failed handshake, a spawn the OS refused, or MAX_RESTARTS crashes.
  # It means "stop the run" — a backend that scored the remaining mutants against a
  # dead daemon would report a score covering a fraction of the work. The CLI maps it
  # to a runtime error (exit 1).
  class DaemonBootError < StandardError; end

  # Tool-side handle for the app-side daemon.
  #
  # Spawns `daemon_server.rb` UNDER THE APP'S BUNDLE/RUBY (tool Ruby, Bundler,
  # and version-manager keys are unset in the child, because Open3 keeps a key
  # the hash omits; the daemon file is loaded by absolute path with `-r`, which
  # bypasses the app bundle that has no mutineer), completes the ready
  # handshake, then ships per-mutant payloads and reads structured verdicts.
  # If the daemon dies mid-run it respawns (bounded) and marks the in-flight
  # mutant `error` rather than corrupting the run. Reuses the cleaned-env spawn
  # and stderr-drain proven in the spike driver and the spawn discipline of
  # ExternalBackend.
  class DaemonClient
    # Absolute path to the daemon entry, loaded app-side by `-r` (bypasses the bundle).
    DAEMON_PATH = File.expand_path("daemon_server.rb", __dir__)
    # How many times to respawn a crashing daemon before aborting the run.
    MAX_RESTARTS = 3

    # @param boot [Hash] boot config sent to the daemon: project_root, boot,
    #   load_paths, framework, rails.
    # @param app_root [String] directory to spawn the daemon in (the app root).
    # @param ruby_version [String, nil] RBENV_VERSION for the app's Ruby.
    #   nil does not copy the tool's version-manager pin.
    # @param gemfile [String, nil] BUNDLE_GEMFILE for the app's bundle (nil = app_root/Gemfile).
    # @param errio [IO] where daemon stderr is drained.
    def initialize(boot:, app_root:, ruby_version: nil, gemfile: nil, errio: $stderr)
      @boot = boot
      @app_root = app_root
      @ruby_version = ruby_version
      @gemfile = gemfile || File.join(app_root, "Gemfile")
      @errio = errio
      @restarts = 0
    end

    # Spawn the daemon and complete the ready handshake. Raises DaemonBootError on
    # failure (surfaced by the CLI as a clean runtime error, not a hang).
    #
    # @return [self]
    def start
      spawn_daemon
      self
    end

    # Run one mutant: ship the payload + covering tests, return the verdict string.
    # On a daemon crash (EOF/dead pipe) respawn (bounded) and return `"error"` for
    # this mutant. Never a wrong verdict, never a wedged run.
    #
    # @param id [Integer] request id (echoed back for ordering safety).
    # @param payload [Hash] mutated ruby under the "code" key, path under "source_file".
    # @param tests [Array<String>] covering test file paths.
    # @param timeout [Numeric] per-mutant wall-clock timeout (seconds).
    # @param worker [Integer] worker slot; the daemon routes the fork to
    #   `<db>-<worker>` for isolation. Defaults to 0 (serial).
    # @return [String] one of survived/killed/error/timeout.
    def request(id:, payload:, tests:, timeout:, worker: 0)
      # close_io nils the pipes, so a client whose respawn never completed would
      # otherwise fail per-mutant forever (NoMethodError on nil) and let the backend
      # score every remaining mutant against nothing. Deadness is a property of the
      # client, not of whichever exception happened to escape.
      raise DaemonBootError, "daemon is not running" if @stdin.nil?

      # A crash can surface on the WRITE (daemon died idle between requests →
      # Errno::EPIPE) as well as the read (EOF), so guard both: either way, respawn
      # for future mutants and score THIS one error (re-running a crash-causing
      # mutant could loop). Never let a dead pipe abort the whole run.
      reply =
        begin
          send_line("id" => id, "worker" => worker, "payload" => payload, "tests" => tests, "timeout" => timeout)
          read_line
        rescue Errno::EPIPE, IOError
          nil
        end
      return reply["verdict"] if reply && reply["id"] == id

      restart!
      "error"
    end

    # Ask the daemon to build the coverage map app-side and return it. One-shot
    # control message (no id). On success, returns
    # `{"map"=>..., "failed_test_files"=>..., "failed_clean_tests"=>...}`.
    # On coverage-build failure, returns
    # `{"map"=>{}, "failed_test_files"=>[], "error"=>...}`.
    # Returns nil if the daemon vanished. The caller then falls back to running
    # the full test set (no narrowing) rather than mis-scoring, except a red
    # unmutated suite which aborts.
    #
    # @return [Hash, nil] the coverage payload, or nil on a dead pipe.
    def coverage
      send_line("cmd" => "coverage")
      read_line
    rescue Errno::EPIPE, IOError
      nil
    end

    # Graceful shutdown; leaves no orphaned daemon/child.
    #
    # @return [void]
    def quit
      return unless @stdin

      send_line("cmd" => "quit") rescue nil # rubocop:disable Style/RescueModifier
      @wait_thr&.join
    ensure
      close_io
    end

    private

    # Environment delta for the daemon child. Open3 merges this onto the parent,
    # so a missing key still leaks. Start from {ExternalBackend.child_env}, which
    # sets tool Ruby, Bundler, gem, and version-manager keys to nil and drops
    # concrete version bins from PATH. Also unset <tt>BUNDLER_*</tt>:
    # <tt>BUNDLER_SETUP</tt> is not a <tt>BUNDLE_</tt> key, and Ruby loads it
    # before the script. Then point the child at the target app.
    #
    # @api private
    # @return [Hash{String => String, nil}]
    def app_env
      env = ExternalBackend.child_env
      ENV.each_key { |key| env[key] = nil if key.start_with?("BUNDLER_") }
      env["BUNDLE_GEMFILE"] = @gemfile
      env["RBENV_VERSION"] = @ruby_version if @ruby_version
      env["RAILS_ENV"] = "test" if rails_boot? && ENV["RAILS_ENV"].nil?
      env
    end

    # True when this daemon boots a Rails app.
    #
    # @api private
    # @return [Boolean]
    def rails_boot?
      @boot[:rails] || @boot["rails"]
    end

    # Spawn the daemon under the app bundle and complete the ready handshake.
    #
    # @return [void]
    # @raise [Mutineer::DaemonBootError] when the daemon fails to boot.
    def spawn_daemon
      # Plain `bundle exec ruby`, NOT `rbenv exec`, which would break CI and any
      # non-rbenv setup. An explicit ruby_version sets RBENV_VERSION so shims
      # select that Ruby. With no pin, shims and `.ruby-version` select it.
      # Everything up to the handshake is terminal, not one mutant's problem: a spawn
      # the OS refuses (EMFILE/ENOMEM under --jobs N, ENOENT when `bundle` does not
      # resolve) and a daemon that dies before accepting the boot payload (EPIPE on
      # the write) both leave a client that cannot recover. Raise the class that ends
      # the run — a SystemCallError would reach the CLI as a usage error (exit 2).
      ready =
        begin
          @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(
            app_env, "bundle", "exec", "ruby",
            "-r", DAEMON_PATH, "-e", "Mutineer::DaemonServer.run", chdir: @app_root
          )
          # Drain daemon stderr to the tool's stderr so child/boot errors are visible.
          # Tracked (not fire-and-forget) so close_io can reclaim it on quit/respawn;
          # the rescue swallows the benign EBADF/IOError raised when close_io closes
          # the pipe out from under an in-flight copy_stream.
          @drain = Thread.new do # rubocop:disable ThreadSafety/NewThread
            IO.copy_stream(@stderr, @errio)
          rescue IOError, Errno::EBADF
            nil
          end

          send_line(@boot)
          read_line
        rescue SystemCallError, IOError => e
          close_io
          raise DaemonBootError, "daemon could not be started: #{e.class}: #{e.message}"
        end

      unless ready && ready["ready"]
        detail = ready && ready["error"] ? ready["error"] : "daemon exited before the handshake"
        close_io
        raise DaemonBootError, "daemon failed to boot under the app bundle: #{detail}"
      end
    end

    # Respawn after a crash, up to MAX_RESTARTS, then hard-fail loudly.
    def restart!
      close_io
      @restarts += 1
      if @restarts > MAX_RESTARTS
        raise DaemonBootError, "daemon crashed #{@restarts} times; aborting the run"
      end

      @errio.puts("[mutineer] daemon crashed — respawning (#{@restarts}/#{MAX_RESTARTS})")
      spawn_daemon
    end

    # Write one JSON object as a line to the daemon.
    #
    # @param obj [Hash] the message to encode.
    # @return [void]
    def send_line(obj)
      @stdin.puts(JSON.generate(obj))
      @stdin.flush
    end

    # Read one JSON reply line; nil on EOF/dead pipe (caller treats as a crash).
    def read_line
      line = @stdout.gets
      line && JSON.parse(line.strip)
    rescue IOError, Errno::EPIPE, JSON::ParserError
      nil
    end

    # Close the IPC pipes, stop the stderr-drain thread, and reap the daemon so a
    # respawn or quit leaves no leaked fd, thread, or zombie.
    #
    # @return [void]
    def close_io
      @drain&.kill # stop the drain BEFORE closing its fd (avoids a copy_stream EBADF)
      [@stdin, @stdout, @stderr].each { |io| io&.close rescue nil } # rubocop:disable Style/RescueModifier
      @wait_thr&.join # reap the exited daemon so respawn/quit leaves no zombie
      @stdin = @stdout = @stderr = @drain = @wait_thr = nil
    end
  end
end
