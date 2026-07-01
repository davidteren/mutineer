# frozen_string_literal: true

require "json"
require "open3"

module Mutineer
  # Raised when the daemon cannot be booted (bad boot path, app error, or it dies on
  # the handshake). The CLI maps it to a runtime error.
  class DaemonBootError < StandardError; end

  # #26/#27 Phase 2a — the TOOL-side handle for the app-side daemon.
  #
  # Spawns `daemon_server.rb` UNDER THE APP'S BUNDLE/RUBY (cleaned env so the gem's
  # bundler context never leaks; the daemon file is loaded by absolute path with
  # `-r`, which bypasses the app bundle that has no mutineer), completes the ready
  # handshake, then ships per-mutant payloads and reads structured verdicts. If the
  # daemon dies mid-run it respawns (bounded) and marks the in-flight mutant `error`
  # rather than corrupting the run. Reuses the cleaned-env spawn + stderr-drain proven
  # in the spike driver and the spawn discipline of ExternalBackend.
  class DaemonClient
    DAEMON_PATH = File.expand_path("daemon_server.rb", __dir__)
    MAX_RESTARTS = 3

    # @param boot [Hash] boot config sent to the daemon: project_root, boot,
    #   load_paths, framework, rails.
    # @param app_root [String] directory to spawn the daemon in (the app root).
    # @param ruby_version [String, nil] RBENV_VERSION for the app's Ruby (nil = inherit).
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
    # this mutant — never a wrong verdict, never a wedged run.
    #
    # @param id [Integer] request id (echoed back for ordering safety).
    # @param payload [Hash] {"code" => mutated ruby, "source_file" => path}.
    # @param tests [Array<String>] covering test file paths.
    # @param timeout [Numeric] per-mutant wall-clock timeout (seconds).
    # @return [String] one of survived/killed/error/timeout.
    def request(id:, payload:, tests:, timeout:)
      # A crash can surface on the WRITE (daemon died idle between requests →
      # Errno::EPIPE) as well as the read (EOF), so guard both: either way, respawn
      # for future mutants and score THIS one error (re-running a crash-causing
      # mutant could loop). Never let a dead pipe abort the whole run.
      reply =
        begin
          send_line("id" => id, "payload" => payload, "tests" => tests, "timeout" => timeout)
          read_line
        rescue Errno::EPIPE, IOError
          nil
        end
      return reply["verdict"] if reply && reply["id"] == id

      restart!
      "error"
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

    # Cleaned environment for the app bundle: strip the gem's bundler/Ruby context so
    # `bundle exec` resolves the APP's Gemfile under the requested Ruby.
    def app_env
      env = ENV.to_h.reject { |k, _| k.start_with?("BUNDLE_", "RUBY", "GEM_") }
      env["BUNDLE_GEMFILE"] = @gemfile
      env["RBENV_VERSION"] = @ruby_version if @ruby_version
      env["RAILS_ENV"] ||= "test" if @boot[:rails] || @boot["rails"]
      env
    end

    def spawn_daemon
      @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(
        app_env, "rbenv", "exec", "bundle", "exec", "ruby",
        "-r", DAEMON_PATH, "-e", "Mutineer::DaemonServer.run", chdir: @app_root
      )
      # Drain daemon stderr to the tool's stderr so child/boot errors are visible.
      # Tracked (not fire-and-forget) so close_io can reclaim it on quit/respawn; the
      # rescue swallows the benign EBADF/IOError raised when close_io closes the pipe
      # out from under an in-flight copy_stream.
      @drain = Thread.new do # rubocop:disable ThreadSafety/NewThread
        IO.copy_stream(@stderr, @errio)
      rescue IOError, Errno::EBADF
        nil
      end

      send_line(@boot)
      ready = read_line
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

    def close_io
      @drain&.kill # stop the drain BEFORE closing its fd (avoids a copy_stream EBADF)
      [@stdin, @stdout, @stderr].each { |io| io&.close rescue nil } # rubocop:disable Style/RescueModifier
      @wait_thr&.join # reap the exited daemon so respawn/quit leaves no zombie
      @stdin = @stdout = @stderr = @drain = @wait_thr = nil
    end
  end
end
