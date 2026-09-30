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
  # Spawns `daemon_server.rb` UNDER THE APP'S BUNDLE/RUBY. The child gets the
  # environment from before the tool's Bundler activated, with
  # <tt>unsetenv_others</tt>, because Open3 keeps a key the hash omits. The
  # daemon file is loaded by absolute path with `-r`, which bypasses the app
  # bundle that has no mutineer. The client completes the ready handshake,
  # then ships per-mutant payloads and reads structured verdicts.
  # If the daemon dies mid-run it respawns (bounded) and marks the in-flight
  # mutant `error` rather than corrupting the run. Reuses the cleaned-env spawn
  # and stderr-drain proven in the spike driver and the spawn discipline of
  # ExternalBackend.
  class DaemonClient
    # Absolute path to the daemon entry, loaded app-side by `-r` (bypasses the bundle).
    DAEMON_PATH = File.expand_path("daemon_server.rb", __dir__)
    # How many times to respawn a crashing daemon before aborting the run.
    MAX_RESTARTS = 3
    # Variables Bundler saves under <tt>BUNDLER_ORIG_*</tt> before it replaces
    # them. Restoring these undoes the tool bundle. Other <tt>BUNDLE_</tt>
    # keys (the app's <tt>BUNDLE_WITHOUT</tt> or <tt>BUNDLE_APP_CONFIG</tt>)
    # stay.
    BUNDLER_SAVED_KEYS = %w[
      BUNDLE_BIN_PATH BUNDLE_GEMFILE BUNDLER_VERSION BUNDLER_SETUP
      GEM_HOME GEM_PATH MANPATH PATH RB_USER_INSTALL RUBYLIB RUBYOPT
    ].freeze
    # Bundler's marker for a variable that was unset before it activated.
    BUNDLER_UNSET = "BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL"
    # rbenv and asdf put a concrete Ruby bin ahead of their shims. chruby has
    # no shims, so a <tt>~/.rubies</tt> bin stays on PATH.
    MANAGED_RUBY_BIN = %r{
      (?:
        /\.rbenv/versions/[^/]+/bin
        |/\.asdf/installs/ruby/[^/]+/bin
      )/?\z
    }x
    # Version-manager pins that would force the tool's Ruby. An explicit
    # +ruby_version+ is applied after these are removed.
    RUBY_PIN_KEYS = %w[RBENV_VERSION ASDF_RUBY_VERSION RBENV_DIR].freeze

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

    # Full environment for the daemon child. Spawn with +unsetenv_others+ so a
    # key deleted here does not leak back from the parent. Undo only what
    # Bundler saved before it activated, then point the child at the target app.
    #
    # @api private
    # @return [Hash{String => String}]
    def app_env
      env = restored_user_env
      RUBY_PIN_KEYS.each { |key| env.delete(key) }
      scrub_managed_ruby_bins!(env)
      env.delete("BUNDLER_SETUP")
      env["BUNDLE_GEMFILE"] = @gemfile
      env["RBENV_VERSION"] = @ruby_version if @ruby_version
      env["RAILS_ENV"] = "test" if rails_boot? && !env.key?("RAILS_ENV")
      env
    end

    # Environment with Bundler's saved originals put back.
    #
    # @api private
    # @return [Hash{String => String}]
    def restored_user_env
      env = ENV.to_h
      BUNDLER_SAVED_KEYS.each do |key|
        saved = env.delete("BUNDLER_ORIG_#{key}")
        next if saved.nil?

        if saved == BUNDLER_UNSET
          env.delete(key)
        else
          env[key] = saved
        end
      end
      env.delete_if { |key, _| key.start_with?("BUNDLER_ORIG_") }
      env
    end

    # Drop rbenv and asdf version bins so shims can select the app Ruby.
    # Leave chruby bins in place.
    #
    # @api private
    # @param env [Hash{String => String}]
    # @return [void]
    def scrub_managed_ruby_bins!(env)
      parts = env["PATH"].to_s.split(File::PATH_SEPARATOR)
      kept = parts.reject { |part| part.match?(MANAGED_RUBY_BIN) }
      return if kept.size == parts.size

      shims = ExternalBackend.version_manager_shim_dirs
      env["PATH"] = (shims + kept).uniq.join(File::PATH_SEPARATOR)
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
            "-r", DAEMON_PATH, "-e", "Mutineer::DaemonServer.run",
            unsetenv_others: true, chdir: @app_root
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
