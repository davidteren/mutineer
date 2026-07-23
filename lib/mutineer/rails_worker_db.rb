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
  # spike-proven). Postgres per-worker DBs (`CREATE DATABASE <db>-<worker>`) are not
  # implemented yet; a non-SQLite config raises a clear NotImplementedError rather
  # than silently mis-routing.
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
      # U10 seam: the config-SHAPING below (per_worker_config) is already
      # adapter-general — it derives correct SQLite *and* Postgres worker-DB names.
      # What's gated is runtime PROVISIONING: SQLite files are created on connect,
      # but Postgres needs an explicit `CREATE DATABASE` per worker (U10). Until that
      # lands, refuse non-SQLite loudly rather than route to a database that doesn't
      # exist until Postgres worker creation is implemented.
      unless adapter.start_with?("sqlite")
        raise NotImplementedError,
              "worker-DB isolation currently provisions SQLite only (got adapter #{adapter.inspect}); " \
              "Postgres per-worker provisioning is U10 (#26/#35) — use a SQLite test DB, or drop --jobs."
      end

      per_worker_config(hash, worker)
    end

    # Pure config-shaping (no AR): given a connection config hash, return the
    # per-worker variant with its database swapped to the worker's own name.
    # Adapter-general — SQLite (`storage/test.sqlite3` → `storage/test-<w>.sqlite3`)
    # and Postgres (`myapp_test` → `myapp_test-<w>`, Rails `parallelize` naming) both
    # fall out of {worker_database_path}. Extracted + unit-tested so the Postgres
    # SHAPE is proven ready for U10 without a live database.
    #
    # @param config_hash [Hash] a connection config hash (symbol or string keys).
    # @param worker [Integer] the worker slot index.
    # @return [Hash] the per-worker config (symbol keys), database swapped.
    # @raise [NotImplementedError] for an in-memory or empty database (no per-worker split).
    def self.per_worker_config(config_hash, worker)
      hash     = config_hash.transform_keys(&:to_sym)
      database = hash[:database].to_s
      if database.empty? || database == ":memory:"
        raise NotImplementedError,
              "worker-DB isolation needs a file/name-backed database (got #{database.inspect})."
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

    # Load a Rails `schema.rb` into the current connection with output silenced
    # (fork child stdout is already File::NULL; this is belt-and-braces).
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
