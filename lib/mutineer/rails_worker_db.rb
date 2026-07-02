# frozen_string_literal: true

module Mutineer
  # #26/#27 Phase 2b (U5) — per-worker database isolation for the daemon path.
  #
  # Loaded APP-SIDE by {DaemonServer} (a sibling gem file, pulled in by absolute path
  # so it bypasses the app bundle — the same trick {DaemonClient} uses to run
  # `daemon_server.rb` under a bundle that has no mutineer). It uses the app's OWN
  # already-booted ActiveRecord and NEVER `require "active_record"` (R10/KTD-8): every
  # method that touches AR first confirms {available?}, so the daemon core stays
  # framework-agnostic and the gem keeps its zero-runtime-dependency promise.
  #
  # Isolation model (KTD-7): each parallel worker gets its OWN database so concurrent
  # forks can't clobber each other's transactional fixtures (the measured #26
  # corruption). {after_fork} runs inside a freshly-forked child and points that
  # child's connection at the worker's database BEFORE any test loads; transactional
  # fixtures then repopulate that isolated database per test.
  #
  # Scope: this pass ships the **SQLite** adapter (per-worker file, hermetic,
  # spike-proven). Postgres per-worker provisioning (`CREATE DATABASE <db>-<worker>` —
  # the measured corruption case) extends {worker_db_config}/{provision} at the marked
  # seam in U10; until then a non-SQLite config raises a clear NotImplementedError
  # rather than silently mis-routing.
  #
  # Honest limit (KTD-5): routing failures surface as `error` via {verify_connection!}.
  # Re-raising an AR error that fires *inside a test body* past Minitest (so an in-test
  # DB failure is `error`, not `killed`) is only observable under concurrent load and
  # is deferred to U6 with the parallel gate — noted, not silently skipped.
  module RailsWorkerDb
    # True when the app has ActiveRecord loaded — the only condition under which any
    # other method here may touch AR. Never triggers an autoload/require of AR itself.
    #
    # @return [Boolean]
    def self.available?
      defined?(ActiveRecord::Base) ? true : false
    end

    # Derive a per-worker database path from a base path by inserting `-<worker>`
    # before the extension. Pure string transform (no AR) so it is unit-testable in
    # the zero-dep suite. `storage/test.sqlite3`, worker 1 -> `storage/test-1.sqlite3`.
    #
    # @param database [String] the base database path.
    # @param worker [Integer] the worker slot index (0..N-1).
    # @return [String] the per-worker database path.
    def self.worker_database_path(database, worker)
      ext = File.extname(database)
      "#{database.delete_suffix(ext)}-#{worker}#{ext}"
    end

    # Build the AR connection config for one worker by copying the app's current
    # (default test) config and swapping in the per-worker database path. SQLite only
    # this pass — a non-SQLite adapter raises so the SQLite-first scope fails loud
    # instead of mis-routing (Postgres is U10).
    #
    # @param worker [Integer] the worker slot index.
    # @return [Hash] a symbol-keyed AR configuration hash for the worker database.
    # @raise [NotImplementedError] when the app's database is non-SQLite or in-memory.
    def self.worker_db_config(worker)
      hash    = ActiveRecord::Base.connection_db_config.configuration_hash
      adapter = hash[:adapter].to_s
      unless adapter.start_with?("sqlite")
        raise NotImplementedError,
              "worker-DB isolation currently supports SQLite only (got adapter #{adapter.inspect}); " \
              "Postgres per-worker provisioning is U10 (#26/#35)."
      end

      database = hash[:database].to_s
      if database.empty? || database == ":memory:"
        raise NotImplementedError,
              "worker-DB isolation needs a file-backed database (got #{database.inspect})."
      end

      hash.merge(database: worker_database_path(database, worker))
    end

    # Child-side (after fork): route this process's ActiveRecord at the worker's own
    # database and confirm it is reachable, so a routing failure reads as `error`
    # (via the daemon's child rescue) rather than a false verdict. Loads the schema
    # into the worker database when a schema path is given (idempotent — schema.rb
    # runs with `force: true`), covering a fresh worker file.
    #
    # @param worker [Integer] the worker slot index.
    # @param schema_path [String, nil] absolute path to `db/schema.rb`, or nil to skip.
    # @return [void]
    def self.after_fork(worker, schema_path = nil)
      return unless available?

      ActiveRecord::Base.establish_connection(worker_db_config(worker))
      load_schema(schema_path) if schema_path
      verify_connection!
    end

    # Explicit, parent-side provisioning: create + schema-load every worker database
    # up front, then restore the app's default connection. This is the EXPLICIT
    # provisioning entry point (V2 — never silent auto-create mid-audit) and the seam
    # U10 extends for Postgres (`CREATE DATABASE` per worker). For SQLite the files are
    # created on connect and the schema load makes them ready; idempotent to re-run.
    #
    # @param worker_count [Integer] number of worker databases to provision.
    # @param schema_path [String, nil] absolute path to `db/schema.rb`, or nil to skip.
    # @return [void]
    def self.provision(worker_count, schema_path)
      return unless available?

      original = ActiveRecord::Base.connection_db_config
      (0...worker_count).each do |worker|
        ActiveRecord::Base.establish_connection(worker_db_config(worker))
        load_schema(schema_path) if schema_path
      end
    ensure
      ActiveRecord::Base.establish_connection(original) if original
    end

    # Load a Rails `schema.rb` into the current connection with its output silenced,
    # so a parent-side {provision} call can never spill schema chatter onto the daemon
    # IPC pipe. (In a fork the child's stdout is already `File::NULL`; this guards the
    # parent path too.)
    #
    # @param schema_path [String] absolute path to `db/schema.rb`.
    # @return [void]
    def self.load_schema(schema_path)
      ActiveRecord::Migration.verbose = false if defined?(ActiveRecord::Migration)
      original = $stdout
      $stdout = File.open(File::NULL, "w")
      load schema_path
    ensure
      $stdout.close unless $stdout.equal?(original)
      $stdout = original
    end

    # Force a round-trip to the freshly-routed connection so a broken route fails HERE
    # (→ `error`) instead of later masquerading as a test failure (→ false `killed`).
    #
    # @return [void]
    def self.verify_connection!
      ActiveRecord::Base.connection.execute("SELECT 1")
    end
  end
end
