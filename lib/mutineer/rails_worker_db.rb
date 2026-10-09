# frozen_string_literal: true

require "digest"

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
  # An {after_fork} failure is a provisioning failure. The daemon child exits
  # 3 and the run stops. It is not scored as a mutant error. Tagging an
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
    # own database and confirm it is reachable. A failure here is a provisioning
    # failure. The daemon ends the run. It does not score the mutant.
    #
    # With `seed: true` (the slot's first use) the worker database first becomes
    # a copy of the base test database, schema and rows, so rows the daemon
    # parent wrote while it booted (initializers, `--require` files) are there,
    # as they are for the in-process backend (#222). The schema is then loaded
    # only when the copy differs from `schema.rb` ({schema_current?}: schema
    # version or stored `schema_sha1`, as in a stale or empty base database):
    # `schema.rb` runs with `force: true`, which drops the copied rows of the
    # tables it defines.
    #
    # @param worker [Integer] the worker slot index.
    # @param schema_path [String, nil] absolute path to `db/schema.rb`, or nil to skip.
    # @param seed [Boolean] copy the base database into the worker database first.
    # @return [void]
    def self.after_fork(worker, schema_path = nil, seed: false)
      return unless available?

      config = worker_db_config(worker)
      base   = ActiveRecord::Base.connection.select_value("SELECT file FROM pragma_database_list WHERE name = 'main'") if seed
      ActiveRecord::Base.establish_connection(config)
      seed_from(base) if seed
      load_schema(schema_path) if schema_path && !schema_current?(schema_path)
      verify_connection!
    end

    # Copy the base test database file into the worker database this fork is
    # now connected to, with the SQLite online backup API: one consistent
    # snapshot of the committed data (WAL included) that replaces whatever the
    # worker file held (an earlier run, or a copy a timeout interrupted). Both
    # ends are files SQLite itself opened, so no path rules are re-derived here.
    #
    # @param base_file [String] the base database file, from `pragma_database_list`.
    # @return [void]
    def self.seed_from(base_file)
      codes  = SQLite3::Constants::ErrorCode
      source = SQLite3::Database.new(base_file, readonly: true)
      source.busy_timeout = 5000
      backup = SQLite3::Backup.new(ActiveRecord::Base.connection.raw_connection, "main", source, "main")
      # Another worker's process can hold a lock on the base file for a moment;
      # BUSY/LOCKED steps are retried for up to 5 seconds, then the copy fails
      # with a message that names the database. The run stops.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until (status = backup.step(-1)) == codes::DONE
        retry_ok = [codes::BUSY, codes::LOCKED].include?(status) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        raise "copying #{base_file} into the worker database failed (SQLite code #{status})" unless retry_ok

        sleep 0.01
      end
    ensure
      backup&.finish
      source&.close
    end

    # True when the current database already holds the schema that `schema.rb`
    # declares: its newest `schema_migrations` row matches the declared version,
    # and the `schema_sha1` Rails stores in `ar_internal_metadata` matches the
    # file, which catches an edited schema with the same version. No stored
    # checksum counts as out of date, as in Rails' own `schema_up_to_date?`.
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
      return false unless conn.table_exists?(metadata)

      conn.select_value("SELECT value FROM #{conn.quote_table_name(metadata)} WHERE key = 'schema_sha1'") ==
        Digest::SHA1.hexdigest(text)
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
    # here, and the run stops, instead of later masquerading as a test failure
    # (a false `killed`).
    #
    # @return [void]
    def self.verify_connection!
      ActiveRecord::Base.connection.execute("SELECT 1")
    end
  end
end
