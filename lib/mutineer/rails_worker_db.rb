# frozen_string_literal: true

require "digest"
require "fileutils"

module Mutineer
  # Per-worker database isolation for the daemon path.
  #
  # Loaded APP-SIDE by {DaemonServer} (a sibling gem file, pulled in by absolute
  # path so it bypasses the app bundle, the same trick {DaemonClient} uses to run
  # `daemon_server.rb` under a bundle that has no mutineer). It uses the app's
  # OWN already-booted ActiveRecord and NEVER `require "active_record"`: every
  # method that touches AR first confirms {available?}, so the daemon core stays
  # framework-agnostic and the gem keeps its zero-runtime-dependency promise.
  #
  # Isolation model: each parallel worker gets its OWN database so concurrent
  # forks cannot clobber each other's transactional fixtures. {after_fork} runs
  # inside a freshly-forked child and points that child's connection at the
  # worker's database BEFORE any test loads; transactional fixtures then
  # repopulate that isolated database per test. On a slot's first use the worker
  # database starts as a copy of the base test database, so it holds what the
  # booted parent wrote, as the in-process backend sees it.
  #
  # Scope: SQLite adapter only (per-worker file, hermetic). Postgres per-worker
  # DBs (`CREATE DATABASE <db>-<worker>`) are not implemented yet; a non-SQLite
  # config raises a clear NotImplementedError rather than silently mis-routing.
  #
  # Routing failures surface as `error` via {verify_connection!}. Tagging an
  # in-test DB failure as `error` (not `killed`) is only observable under
  # concurrent load and is not yet implemented.
  module RailsWorkerDb
    # True when the app has ActiveRecord loaded. The only condition under which
    # any other method here may touch AR. Never triggers an autoload/require of
    # AR itself.
    #
    # @return [Boolean]
    def self.available?
      defined?(ActiveRecord::Base) ? true : false
    end

    # Derive a per-worker database path from a base path by inserting `-<worker>`
    # before the extension. Pure string transform (no AR) so it is unit-testable
    # in the zero-dep suite. `storage/test.sqlite3`, worker 1 ->
    # `storage/test-1.sqlite3`.
    #
    # @param database [String] the base database path.
    # @param worker [Integer] the worker slot index (0..N-1).
    # @return [String] the per-worker database path.
    def self.worker_database_path(database, worker)
      ext = File.extname(database)
      "#{database.delete_suffix(ext)}-#{worker}#{ext}"
    end

    # Build the AR connection config for one worker by copying the app's current
    # (default test) config and swapping in the per-worker database path. SQLite
    # only this pass: a non-SQLite adapter raises so the SQLite-first scope fails
    # loud instead of mis-routing.
    #
    # @param worker [Integer] the worker slot index.
    # @return [Hash] a symbol-keyed AR configuration hash for the worker database.
    # @raise [NotImplementedError] when the app's database is non-SQLite or in-memory.
    def self.worker_db_config(worker)
      hash    = ActiveRecord::Base.connection_db_config.configuration_hash
      adapter = hash[:adapter].to_s
      # Config shaping (per_worker_config) is already adapter-general: it derives
      # correct SQLite and Postgres worker-DB names. What is gated is runtime
      # provisioning: SQLite files are created on connect, but Postgres needs an
      # explicit `CREATE DATABASE` per worker. Until that lands, refuse non-SQLite
      # loudly rather than route to a database that does not exist.
      unless adapter.start_with?("sqlite")
        raise NotImplementedError,
              "worker-DB isolation currently provisions SQLite only (got adapter #{adapter.inspect}); " \
              "Postgres per-worker provisioning is not yet supported. Use a SQLite test DB with --daemon, or drop --daemon to run serially."
      end

      per_worker_config(hash, worker)
    end

    # Pure config-shaping (no AR): given a connection config hash, return the
    # per-worker variant with its database swapped to the worker's own name.
    # Adapter-general: SQLite (`storage/test.sqlite3` -> `storage/test-<w>.sqlite3`)
    # and Postgres (`myapp_test` -> `myapp_test-<w>`, Rails `parallelize` naming)
    # both fall out of {worker_database_path}. Extracted and unit-tested so the
    # Postgres shape is proven ready without a live database.
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

    # Child-side (after fork): route this process's ActiveRecord at the worker's
    # own database and confirm it is reachable, so a routing failure reads as
    # `error` (via the daemon's child rescue) rather than a false verdict.
    #
    # With `seed: true` (the slot's first use) the worker database first becomes
    # a copy of the base test database, schema and rows, so rows the daemon
    # parent wrote while it booted (initializers, `--require` files) are there,
    # as they are for the in-process backend (#222). The schema is then loaded
    # only when the worker's schema version differs from `schema.rb` (a stale
    # or empty base database): `schema.rb` runs with `force: true`, which drops
    # the copied rows of the tables it defines.
    #
    # @param worker [Integer] the worker slot index.
    # @param schema_path [String, nil] absolute path to `db/schema.rb`, or nil to skip.
    # @param seed [Boolean] copy the base database into the worker database first.
    # @return [void]
    def self.after_fork(worker, schema_path = nil, seed: false)
      return unless available?

      config = worker_db_config(worker)
      seed_from_base(worker) if seed
      ActiveRecord::Base.establish_connection(config)
      load_schema(schema_path) if schema_path && !schema_current?(schema_path)
      verify_connection!
    end

    # Copy the base test database (the connection this fork inherited) into the
    # worker's database file with `VACUUM INTO`: one consistent snapshot of the
    # committed data, WAL included. A stale worker file (an earlier run, or a
    # copy a timeout interrupted) is removed first, since `VACUUM INTO` needs an
    # absent or empty target.
    #
    # @param worker [Integer] the worker slot index.
    # @return [void]
    def self.seed_from_base(worker)
      conn   = ActiveRecord::Base.connection
      base   = conn.select_value("SELECT file FROM pragma_database_list WHERE name = 'main'")
      target = worker_database_path(base, worker)
      ["", "-wal", "-shm", "-journal"].each { |suffix| FileUtils.rm_f(target + suffix) }
      conn.execute("VACUUM INTO #{conn.quote(target)}")
    end

    # True when the current database already holds the schema that `schema.rb`
    # declares: its newest `schema_migrations` row matches the declared version,
    # and the `schema_sha1` Rails stores in `ar_internal_metadata` (when present)
    # matches the file, which catches an edited schema with the same version.
    #
    # @param schema_path [String] absolute path to `db/schema.rb`.
    # @return [Boolean]
    def self.schema_current?(schema_path)
      text    = File.read(schema_path)
      version = schema_file_version(text)
      conn = ActiveRecord::Base.connection
      base       = ActiveRecord::Base
      migrations = "#{base.table_name_prefix}#{base.schema_migrations_table_name}#{base.table_name_suffix}"
      metadata   = "#{base.table_name_prefix}#{base.internal_metadata_table_name}#{base.table_name_suffix}"
      return false unless version && conn.table_exists?(migrations)
      return false unless conn.select_values("SELECT version FROM #{conn.quote_table_name(migrations)}").map(&:to_i).max == version
      return true unless conn.table_exists?(metadata)

      stored = conn.select_value("SELECT value FROM #{conn.quote_table_name(metadata)} WHERE key = 'schema_sha1'")
      stored.nil? || stored == Digest::SHA1.hexdigest(text)
    end

    # The version a `schema.rb` declares in `define(version: ...)`, or nil. Pure
    # string parse (no AR) so it is unit-testable in the zero-dep suite.
    #
    # @param text [String] the `schema.rb` source.
    # @return [Integer, nil]
    def self.schema_file_version(text)
      text[/define\(version:\s*([\d_]+)/, 1]&.delete("_")&.to_i
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

    # Force a round-trip to the freshly-routed connection so a broken route fails
    # HERE (→ `error`) instead of later masquerading as a test failure
    # (→ false `killed`).
    #
    # @return [void]
    def self.verify_connection!
      ActiveRecord::Base.connection.execute("SELECT 1")
    end
  end
end
