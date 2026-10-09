# frozen_string_literal: true

require "json"
require "io/wait"
require "open3"
require_relative "external_backend"
require_relative "rails_run_env"

module Mutineer
  # Raised when the daemon cannot be booted or is gone for good: a bad boot path, an
  # app error, a failed handshake, a spawn the OS refused, or MAX_RESTARTS crashes.
  # It means "stop the run" — a backend that scored the remaining mutants against a
  # dead daemon would report a score covering a fraction of the work. The CLI maps it
  # to a runtime error (exit 1).
  class DaemonBootError < StandardError; end

  # A boot that has not answered the handshake within DaemonClient::BOOT_TIMEOUT
  # (#101). Unlike other boot errors it is not worth retrying with a second
  # daemon, which would wait just as long.
  class DaemonBootTimeout < DaemonBootError; end

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
    # Seconds a verdict may lag the request's own timeout. The daemon enforces
    # that timeout on the mutant child, so a reply later than this means the
    # daemon itself is wedged (#101): it is killed and respawned.
    REPLY_GRACE = 30
    # Seconds the daemon gets to boot the app and answer the handshake. A boot
    # that never returns ends the run instead of hanging it (#101).
    BOOT_TIMEOUT = 600
    # Bundler's marker for a variable that was unset before it activated.
    BUNDLER_UNSET = "BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL"

    # @param boot [Hash] boot config sent to the daemon: project_root, boot,
    #   load_paths, framework, rails.
    # @param app_root [String] directory to spawn the daemon in (the app root).
    # @param ruby_version [String, nil] RBENV_VERSION for the app's Ruby.
    #   nil keeps a pin already in the environment. That pin is often the
    #   Ruby that started the tool.
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

    # How many database configs the booted test environment reported.
    # 1 when the daemon did not send a count.
    #
    # @return [Integer]
    def database_count
      @database_count || 1
    end

    # Ask the daemon to create `slots` worker databases. Raises when the copy
    # fails or another run holds the database, so the caller stops before any
    # mutant is scored.
    #
    # @param slots [Integer] worker slots to create.
    # @return [void]
    # @raise [Mutineer::DaemonBootError]
    def provision(slots)
      raise DaemonBootError, "daemon is not running" if @stdin.nil?

      send_line("cmd" => "provision", "slots" => slots)
      reply = read_line(BOOT_TIMEOUT)
      return if reply && reply["ok"]

      detail = reply && reply["error"] ? reply["error"] : "provision failed"
      raise DaemonBootError, detail
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
          read_line(timeout + REPLY_GRACE)
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
      @wait_thr&.join(REPLY_GRACE) # a wedged daemon is killed by close_io
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
      scrub_managed_ruby_bins!(env)
      env.delete("BUNDLER_SETUP")
      env["BUNDLE_GEMFILE"] = @gemfile
      env["RBENV_VERSION"] = @ruby_version if @ruby_version
      env["RAILS_ENV"] = "test" if rails_boot? && !env.key?("RAILS_ENV")
      # The daemon loads tests after boot. Rails reads this when parallelize runs.
      RailsRunEnv.pin_child!(env)
      env
    end

    # Environment with every <tt>BUNDLER_ORIG_*</tt> value put back. Bundler
    # writes one saved key per variable it replaced. Restoring all of them
    # undoes the tool bundle without a copied key list.
    #
    # @api private
    # @return [Hash{String => String}]
    def restored_user_env
      env = ENV.to_h
      restored = []
      env.keys.each do |saved_key|
        next unless saved_key.start_with?("BUNDLER_ORIG_")

        key = saved_key.delete_prefix("BUNDLER_ORIG_")
        saved = env.delete(saved_key)
        restored << key
        if saved == BUNDLER_UNSET
          env.delete(key)
        else
          env[key] = saved
        end
      end
      # A parent require must not run in the app, even when Bundler saved it.
      %w[RUBYOPT RUBYLIB].each { |key| env.delete(key) }
      # No saved original means the value belongs to the tool process.
      %w[GEM_HOME GEM_PATH BUNDLE_PATH BUNDLE_WITHOUT BUNDLER_VERSION].each do |key|
        env.delete(key) unless restored.include?(key)
      end
      env
    end

    # Drop rbenv and asdf version bins so shims can select the app Ruby.
    # Leave those bins in place when no shim directory exists, so +bundle+
    # stays on PATH. Leave chruby bins in place.
    #
    # @api private
    # @param env [Hash{String => String}]
    # @return [void]
    def scrub_managed_ruby_bins!(env)
      parts = env["PATH"].to_s.split(File::PATH_SEPARATOR)
      rbenv = rbenv_shim_dirs(env)
      asdf = asdf_shim_dirs(env)
      dropped_rbenv = false
      dropped_asdf = false
      kept = parts.reject do |part|
        if rbenv_version_bin?(part, env) && rbenv.any?
          dropped_rbenv = true
        elsif asdf_version_bin?(part, env) && asdf.any?
          dropped_asdf = true
        else
          false
        end
      end
      return if kept.size == parts.size

      shims = []
      shims.concat(rbenv) if dropped_rbenv
      shims.concat(asdf) if dropped_asdf
      env["PATH"] = (shims + kept).uniq.join(File::PATH_SEPARATOR)
    end

    # Existing rbenv shim directory. +RBENV_ROOT+ wins. Otherwise the home
    # directory's <tt>.rbenv</tt> is used.
    #
    # @api private
    # @param env [Hash{String => String}]
    # @return [Array<String>]
    def rbenv_shim_dirs(env)
      root = rbenv_root(env)
      return [] if root.nil?

      dir = File.join(root, "shims")
      File.directory?(dir) ? [dir] : []
    end

    # rbenv install root. +RBENV_ROOT+ wins over <tt>~/.rbenv</tt>.
    #
    # @api private
    # @param env [Hash{String => String}]
    # @return [String, nil]
    def rbenv_root(env)
      root = env["RBENV_ROOT"]
      return File.expand_path(root) if root && !root.empty?

      home = env["HOME"]
      return nil if home.nil? || home.empty?

      File.join(home, ".rbenv")
    end

    # Existing asdf shim directories. A custom install uses +ASDF_DATA_DIR+.
    #
    # @api private
    # @param env [Hash{String => String}]
    # @return [Array<String>]
    def asdf_shim_dirs(env)
      dirs = []
      data = env["ASDF_DATA_DIR"]
      dirs << File.join(data, "shims") if data && !data.empty?
      home = env["HOME"]
      dirs << File.join(home, ".asdf", "shims") if home && !home.empty?
      dirs.select { |dir| File.directory?(dir) }.uniq
    end

    # True when `part` is a version bin under the active rbenv root.
    #
    # @api private
    # @param part [String] one PATH entry.
    # @param env [Hash{String => String}]
    # @return [Boolean]
    def rbenv_version_bin?(part, env)
      root = rbenv_root(env)
      return false if root.nil?

      prefix = File.join(root, "versions")
      File.expand_path(part).match?(%r{\A#{Regexp.escape(prefix)}/[^/]+/bin/?\z})
    end

    # True when `part` is an asdf Ruby version bin under ~/.asdf or +ASDF_DATA_DIR+.
    #
    # @api private
    # @param part [String] one PATH entry.
    # @param env [Hash{String => String}]
    # @return [Boolean]
    def asdf_version_bin?(part, env)
      return true if part.match?(%r{/\.asdf/installs/ruby/[^/]+/bin/?\z})

      data = env["ASDF_DATA_DIR"]
      return false if data.nil? || data.empty?

      prefix = File.join(File.expand_path(data), "installs", "ruby")
      File.expand_path(part).match?(%r{\A#{Regexp.escape(prefix)}/[^/]+/bin/?\z})
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
      # non-rbenv setup. An explicit ruby_version replaces RBENV_VERSION.
      # With no argument, a pin already in the environment stays. That pin is
      # often the Ruby that started the tool. `.ruby-version` applies only
      # when no pin is set. rbenv and asdf version bins leave PATH when a shim
      # directory exists. chruby bins stay.
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
          read_line(BOOT_TIMEOUT)
        rescue SystemCallError, IOError => e
          close_io
          raise DaemonBootError, "daemon could not be started: #{e.class}: #{e.message}"
        end

      unless ready && ready["ready"]
        detail =
          if ready && ready["error"] then ready["error"]
          elsif @timed_out then "the daemon did not finish booting within #{BOOT_TIMEOUT}s"
          else "daemon exited before the handshake"
          end
        timed_out = @timed_out
        close_io
        raise (timed_out ? DaemonBootTimeout : DaemonBootError), "daemon failed to boot under the app bundle: #{detail}"
      end
      @database_count = ready["database_count"] || 1
    end

    # Respawn after a crash, up to MAX_RESTARTS, then hard-fail loudly.
    def restart!
      close_io
      @restarts += 1
      if @restarts > MAX_RESTARTS
        raise DaemonBootError, "daemon crashed or stopped answering #{@restarts} times; aborting the run"
      end

      cause = @timed_out ? "stopped answering" : "crashed"
      @errio.puts("[mutineer] daemon #{cause} — respawning (#{@restarts}/#{MAX_RESTARTS})")
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

    # Read one JSON reply line; nil on EOF/dead pipe, or when no line arrives
    # within `timeout` seconds (caller treats either as a crash).
    #
    # @param timeout [Numeric, nil] seconds to wait; nil waits for the reply.
    # @return [Hash, nil]
    def read_line(timeout = nil)
      @timed_out = timeout && !@stdout.wait_readable(timeout)
      return nil if @timed_out

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
      # A wedged daemon may never read the closed stdin, so the reap below would
      # wait forever: kill it first. An exited daemon makes this a no-op.
      begin
        Process.kill(:KILL, @wait_thr.pid) if @wait_thr&.alive?
      rescue Errno::ESRCH
        nil # it exited between the check and the kill
      end
      @drain&.kill # stop the drain BEFORE closing its fd (avoids a copy_stream EBADF)
      [@stdin, @stdout, @stderr].each { |io| io&.close rescue nil } # rubocop:disable Style/RescueModifier
      @wait_thr&.join # reap the exited daemon so respawn/quit leaves no zombie
      @stdin = @stdout = @stderr = @drain = @wait_thr = nil
    end
  end
end
