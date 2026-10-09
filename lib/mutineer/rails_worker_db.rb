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
  # worker's database BEFORE any test loads.
  #
  # SQLite copies the base file on a slot's first use ({after_fork} with
  # `seed: true`). Postgres and MySQL copy once, before any worker daemon starts
  # ({provision}). A later fork only connects. Both servers roll back a killed
  # fork's open transaction, so the SQLite re-seed after `error` or `timeout` is
  # skipped. Rows a test commits outside a transaction stay in the slot.
  #
  # MySQL has no template database. Each slot is created empty, the app schema
  # is loaded with ActiveRecord::Tasks::DatabaseTasks, and rows are copied
  # table by table. `mysql2` and `trilogy` are accepted. Any other adapter
  # raises NotImplementedError rather than routing at a database that does not exist.
  module RailsWorkerDb
    # Postgres cuts an unquoted identifier at this many bytes.
    POSTGRES_NAME_LIMIT = 63
    # MySQL cuts a database name at this many bytes. The shortening rule matches
    # Postgres. A byte limit stays inside the 64-character limit for this name.
    MYSQL_NAME_LIMIT = 64
    # How many named GET_LOCK slots stand in for one shared lock. MySQL's
    # GET_LOCK is exclusive, so each holder takes one free name.
    MYSQL_LOCK_SLOTS = 64
    # Infix that keeps a worker database off Rails' own `<base>-<n>` names.
    WORKER_NAME_MARK = "-mutineer-"
    # Database we connect to while the test database is a template. Advisory
    # locks are per database, so every run must take them here, not on a slot.
    MAINTENANCE_DATABASE = "postgres"

    # True when the app has ActiveRecord loaded. The only condition under which
    # any other method here may touch AR. Never triggers an autoload/require of
    # AR itself.
    #
    # @return [Boolean]
    def self.available?
      defined?(ActiveRecord::Base) ? true : false
    end

    # Derive a per-worker SQLite path by inserting `-<worker>` before the
    # extension. Pure string transform (no AR). `storage/test.sqlite3`, worker
    # 1 -> `storage/test-1.sqlite3`.
    #
    # @param database [String] the base database path.
    # @param worker [Integer] the worker slot index (0..N-1).
    # @return [String] the per-worker database path.
    def self.worker_database_path(database, worker)
      ext = File.extname(database)
      "#{database.delete_suffix(ext)}-#{worker}#{ext}"
    end

    # Worker database name: `<base>-mutineer-<slot>`. When that is longer than
    # `limit` bytes, the base is shortened and a hash of the full base is added
    # so two slots, and two long bases that share a prefix, stay distinct.
    #
    # @param base [String] the test database name.
    # @param slot [Integer] the worker slot index.
    # @param limit [Integer] maximum name length in bytes.
    # @return [String] a name of at most `limit` bytes.
    def self.worker_database_name(base, slot, limit)
      suffix = "#{WORKER_NAME_MARK}#{slot}"
      full = "#{base}#{suffix}"
      return full if full.bytesize <= limit

      hash = Digest::SHA256.hexdigest(base)[0, 8]
      tail = "-#{hash}#{suffix}"
      room = limit - tail.bytesize
      room = 0 if room.negative?
      "#{base.b[0, room]}#{tail}"
    end

    # Postgres worker database name. See {worker_database_name}.
    #
    # @param base [String] the test database name.
    # @param slot [Integer] the worker slot index.
    # @return [String] a name of at most {POSTGRES_NAME_LIMIT} bytes.
    def self.postgres_worker_database(base, slot)
      worker_database_name(base, slot, POSTGRES_NAME_LIMIT)
    end

    # MySQL worker database name. See {worker_database_name}.
    #
    # @param base [String] the test database name.
    # @param slot [Integer] the worker slot index.
    # @return [String] a name of at most {MYSQL_NAME_LIMIT} bytes.
    def self.mysql_worker_database(base, slot)
      worker_database_name(base, slot, MYSQL_NAME_LIMIT)
    end

    # True when `name` is one of this run's exact worker database names.
    # Equality only: a SQL `LIKE` would treat `_` in the base as a wildcard,
    # so `my_app_test-mutineer-1` must not match base `myXappXtest`.
    # `limit` defaults to the Postgres limit so existing callers stay valid.
    #
    # @param base [String] the test database name.
    # @param name [String] a database name we might drop.
    # @param slots [Integer] how many worker slots this run owns.
    # @param limit [Integer] name limit in bytes. {POSTGRES_NAME_LIMIT} or {MYSQL_NAME_LIMIT}.
    # @return [Boolean]
    def self.owned_database?(base, name, slots:, limit: POSTGRES_NAME_LIMIT)
      (0...slots).any? { |slot| worker_database_name(base, slot, limit) == name }
    end

    # Build the AR connection config for one worker from the app's current
    # test config. SQLite and Postgres get a per-worker database name. Anything
    # else raises.
    #
    # @param worker [Integer] the worker slot index.
    # @return [Hash] a symbol-keyed AR configuration hash for the worker database.
    # @raise [NotImplementedError] when the adapter has no worker database yet, or the database is in-memory.
    def self.worker_db_config(worker)
      per_worker_config(current_config_hash, worker)
    end

    # Pure config shaping (no AR): swap in the worker database name.
    # SQLite keeps {worker_database_path}. Postgres uses {postgres_worker_database}.
    # MySQL (`mysql2` or `trilogy`) uses {mysql_worker_database}.
    #
    # @param config_hash [Hash] a connection config hash (symbol or string keys).
    # @param worker [Integer] the worker slot index.
    # @return [Hash] the per-worker config (symbol keys), database swapped.
    # @raise [NotImplementedError] for an in-memory database, an empty name, or an adapter other than SQLite, Postgres, or MySQL.
    def self.per_worker_config(config_hash, worker)
      hash     = config_hash.transform_keys(&:to_sym)
      database = hash[:database].to_s
      adapter  = hash[:adapter].to_s
      if database.empty? || database == ":memory:"
        raise NotImplementedError,
              "worker-DB isolation needs a file or named database (got #{database.inspect})."
      end

      name =
        if sqlite_adapter?(adapter)
          worker_database_path(database, worker)
        elsif postgres_adapter?(adapter)
          postgres_worker_database(database, worker)
        elsif mysql_adapter?(adapter)
          mysql_worker_database(database, worker)
        else
          raise NotImplementedError,
                "worker-DB isolation does not support adapter #{adapter.inspect} yet."
        end
      hash.merge(database: name)
    end

    # Create each worker database before any worker daemon starts.
    # SQLite is a no-op: the file is copied on first use. Postgres drops and
    # recreates each exact slot name from the test database. MySQL creates each
    # slot, loads the schema, and copies rows. The caller must be the only
    # daemon connected to that test database.
    #
    # @param slots [Integer] how many worker slots to create (0..slots-1).
    # @return [void]
    # @raise [NotImplementedError] for an adapter other than SQLite, Postgres, or MySQL.
    # @raise [RuntimeError] when the copy cannot be made, or another run holds the lock.
    def self.provision(slots)
      return unless available?

      count = Integer(slots)
      return if count < 1
      return if sqlite_adapter?(current_adapter)

      if postgres_adapter?(current_adapter)
        provision_postgres(count)
        return
      end
      if mysql_adapter?(current_adapter)
        provision_mysql(count)
        return
      end

      raise NotImplementedError,
            "worker-DB isolation does not support adapter #{current_adapter.inspect} yet."
    end

    # Take the shared run lock and drop this process's connection to the test
    # database. Worker daemons call this at boot. They do not create databases.
    # SQLite has no lock here. The file copy still happens in {after_fork}.
    #
    # @return [void]
    # @raise [RuntimeError] when another run holds the exclusive lock.
    def self.prepare_worker!
      return unless available?
      return if sqlite_adapter?(current_adapter)

      if mysql_adapter?(current_adapter)
        prepare_mysql_worker!
        return
      end
      return unless postgres_adapter?(current_adapter)

      hash = current_config_hash
      base = hash[:database].to_s
      conn = open_maintenance_connection(hash, base)
      unless try_lock(conn, base, shared: true)
        conn.close
        raise "another Mutineer run is using #{base}"
      end

      @lock_connection = conn
      disconnect_app!
    end

    # Point this process at one worker database. Postgres and MySQL only connect.
    # The slot was copied at {provision}.
    #
    # @param slot [Integer] the worker slot index.
    # @return [void]
    def self.connect(slot)
      ActiveRecord::Base.establish_connection(worker_db_config(slot))
    end

    # How many database configs the test environment declares. One is normal.
    # More than one means the run must use a single worker.
    #
    # @return [Integer]
    def self.database_count
      return 1 unless available?

      env = ENV["RAILS_ENV"].to_s
      env = "test" if env.empty?
      list = ActiveRecord::Base.configurations.configs_for(env_name: env)
      count = list.size
      count < 1 ? 1 : count
    rescue StandardError
      1
    end

    # Child-side (after fork): route this process's ActiveRecord at the worker's
    # own database and confirm it is reachable, so a routing failure reads as
    # `error` rather than a false verdict.
    #
    # SQLite with `seed: true` copies the base file first, then loads `schema.rb`
    # only when the copy differs from that file. Postgres and MySQL ignore `seed`
    # and the schema path: the slot was copied at {provision}, and loading
    # `schema.rb` again would drop those rows.
    #
    # @param worker [Integer] the worker slot index.
    # @param schema_path [String, nil] absolute path to `db/schema.rb`, or nil to skip.
    # @param seed [Boolean] copy the base SQLite file into the worker file first.
    # @return [void]
    def self.after_fork(worker, schema_path = nil, seed: false)
      return unless available?

      forget_lock_connection_after_fork!
      if postgres_adapter?(current_adapter) || mysql_adapter?(current_adapter)
        connect(worker)
        verify_connection!
        return
      end

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
      # with a message that names the database (scored `error`).
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
    # HERE (then `error`) instead of later masquerading as a test failure
    # (then a false `killed`).
    #
    # @return [void]
    def self.verify_connection!
      ActiveRecord::Base.connection.execute("SELECT 1")
    end

    # Symbol-keyed connection hash for the database the app booted. Does not
    # open a new connection.
    #
    # @return [Hash]
    def self.current_config_hash
      ActiveRecord::Base.connection_db_config.configuration_hash.transform_keys(&:to_sym)
    end

    # Adapter name from {current_config_hash}.
    #
    # @return [String]
    def self.current_adapter
      current_config_hash[:adapter].to_s
    end

    # @param adapter [String]
    # @return [Boolean]
    def self.sqlite_adapter?(adapter)
      adapter.start_with?("sqlite")
    end

    # @param adapter [String]
    # @return [Boolean]
    def self.postgres_adapter?(adapter)
      adapter == "postgres" || adapter.start_with?("postgres")
    end

    # True for the mysql2 and trilogy adapters. The old `mysql` gem is not included.
    #
    # @param adapter [String]
    # @return [Boolean]
    def self.mysql_adapter?(adapter)
      adapter == "mysql2" || adapter == "trilogy"
    end

    # Drop and recreate slots `0...count` from the booted test database.
    # Holds the exclusive advisory lock only for the copy, then a shared lock
    # for the rest of this process so a second run cannot drop those databases.
    #
    # @param count [Integer]
    # @return [void]
    def self.provision_postgres(count)
      hash = current_config_hash
      base = hash[:database].to_s
      conn = open_maintenance_connection(hash, base)
      unless try_lock(conn, base, shared: false)
        conn.close
        raise "another Mutineer run is using #{base}"
      end

      begin
        disconnect_app!
        count.times do |slot|
          name = postgres_worker_database(base, slot)
          unless owned_database?(base, name, slots: count)
            raise "refusing to drop #{name}"
          end

          recreate_from_template(conn, name, base)
        end
      rescue StandardError => e
        unlock(conn, base)
        conn.close
        raise e.message.start_with?("could not provision", "another Mutineer run", "refusing to drop") ? e : provision_failure(base, base, e.message)
      end

      unlock(conn, base)
      unless try_lock(conn, base, shared: true)
        conn.close
        raise "another Mutineer run is using #{base}"
      end
      @lock_connection = conn
      warn "[mutineer] provisioned #{count} postgres worker database(s) from #{base}"
    end

    # Open a session on {MAINTENANCE_DATABASE} with the app's Postgres credentials.
    # Uses the `pg` client the app already loaded. The gem does not depend on it.
    #
    # @param config_hash [Hash]
    # @param base [String] test database name, named in the error if this fails.
    # @return [PG::Connection]
    def self.open_maintenance_connection(config_hash, base)
      unless defined?(PG::Connection)
        raise "could not provision #{base}: the app's pg client is not loaded"
      end

      opts = { dbname: MAINTENANCE_DATABASE }
      host = config_hash[:host].to_s
      opts[:host] = host unless host.empty?
      port = config_hash[:port]
      opts[:port] = port if port && !port.to_s.empty?
      user = config_hash[:username] || config_hash[:user]
      opts[:user] = user if user && !user.to_s.empty?
      password = config_hash[:password]
      opts[:password] = password if password && !password.to_s.empty?
      PG::Connection.open(opts)
    rescue StandardError => e
      raise e if e.message.start_with?("could not provision ")

      raise "could not provision #{base}: #{e.message}"
    end

    # @param conn [PG::Connection]
    # @param base [String]
    # @param shared [Boolean] shared lock when true, exclusive when false.
    # @return [Boolean]
    def self.try_lock(conn, base, shared:)
      k1, k2 = lock_keys(base)
      sql = shared ? "SELECT pg_try_advisory_lock_shared($1, $2)" : "SELECT pg_try_advisory_lock($1, $2)"
      conn.exec_params(sql, [k1, k2]).getvalue(0, 0) == "t"
    end

    # Release one advisory lock this session holds for `base`.
    #
    # @param conn [PG::Connection]
    # @param base [String]
    # @return [void]
    def self.unlock(conn, base)
      k1, k2 = lock_keys(base)
      conn.exec_params("SELECT pg_advisory_unlock($1, $2)", [k1, k2])
    end

    # Two signed 32-bit keys for `pg_try_advisory_lock(int, int)`, from the base name.
    #
    # @param base [String]
    # @return [Array(Integer, Integer)]
    def self.lock_keys(base)
      Digest::SHA256.digest("mutineer-run:#{base}").unpack("l>l>")
    end

    # Replace `name` with a template copy of `base`. Terminates other sessions
    # on the slot only. A session on `base` is left alone and fails the copy.
    #
    # @param conn [PG::Connection]
    # @param name [String] exact worker database name.
    # @param base [String] test database used as the template.
    # @return [void]
    def self.recreate_from_template(conn, name, base)
      conn.exec("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = #{conn.escape_literal(name)} AND pid <> pg_backend_pid()")
      conn.exec("DROP DATABASE IF EXISTS #{quote_ident(name)}")
      conn.exec("CREATE DATABASE #{quote_ident(name)} TEMPLATE #{quote_ident(base)}")
    rescue StandardError => e
      raise provision_failure(base, name, e.message)
    end

    # Close every connection this process holds through ActiveRecord, so the
    # test database can be used as a Postgres template.
    #
    # @return [void]
    def self.disconnect_app!
      handler = ActiveRecord::Base.connection_handler
      if handler.respond_to?(:clear_all_connections!)
        handler.clear_all_connections!
      else
        ActiveRecord::Base.connection_pool.disconnect!
      end
    end

    # The child inherited the parent's lock session. Drop the Ruby wrapper
    # without sending a disconnect, so the parent's advisory lock stays held.
    # The child's file descriptor closes when the child exits. That does not
    # close the parent's copy of the same socket.
    #
    # @return [void]
    def self.forget_lock_connection_after_fork!
      conn = @lock_connection
      @lock_connection = nil
      return unless conn

      ObjectSpace.undefine_finalizer(conn)
    end

    # Quote a database name for a Postgres identifier. `CREATE DATABASE` cannot
    # take a bound parameter for the name.
    #
    # @param name [String]
    # @return [String]
    def self.quote_ident(name)
      raise ArgumentError, "database name is empty" if name.nil? || name.empty?

      %("#{name.gsub('"', '""')}")
    end

    # Failure text for a copy that did not happen. Names the database and the
    # server's cause. A busy template also says to close other sessions.
    #
    # @param base [String]
    # @param name [String]
    # @param cause [String]
    # @return [String]
    def self.provision_failure(base, name, cause)
      message = "could not provision #{name} from #{base}: #{cause}"
      message += ". Close other sessions on #{base}." if cause.match?(/other users|being accessed/i)
      message
    end

    # Create MySQL slots `0...count`, load the app schema into each, and copy
    # rows from the test database. Holds every GET_LOCK name only while copying,
    # then one shared name for the rest of this process.
    #
    # @param count [Integer]
    # @return [void]
    def self.provision_mysql(count)
      hash = current_config_hash
      base = hash[:database].to_s
      conn = open_mysql_connection(hash, base)
      unless try_mysql_lock(conn, base, shared: false)
        conn.close
        raise "another Mutineer run is using #{base}"
      end

      begin
        disconnect_app!
        count.times do |slot|
          name = mysql_worker_database(base, slot)
          raise "refusing to drop #{name}" unless owned_database?(base, name, slots: count, limit: MYSQL_NAME_LIMIT)

          begin
            recreate_mysql_database(conn, name)
            load_mysql_schema(hash, name, base)
            copy_mysql_rows(conn, base, name)
          rescue StandardError => e
            raise e if provision_wrapped?(e)

            raise provision_failure(base, name, e.message)
          end
        end
      rescue StandardError => e
        release_mysql_lock(conn)
        conn.close
        raise e if provision_wrapped?(e)

        raise provision_failure(base, base, e.message)
      end

      release_mysql_lock(conn)
      unless try_mysql_lock(conn, base, shared: true)
        conn.close
        raise "another Mutineer run is using #{base}"
      end
      @lock_connection = conn
      warn "[mutineer] provisioned #{count} mysql worker database(s) from #{base}"
    end

    # Take one shared GET_LOCK name and drop this process's app connection.
    #
    # @return [void]
    def self.prepare_mysql_worker!
      hash = current_config_hash
      base = hash[:database].to_s
      conn = open_mysql_connection(hash, base)
      unless try_mysql_lock(conn, base, shared: true)
        conn.close
        raise "another Mutineer run is using #{base}"
      end

      @lock_connection = conn
      disconnect_app!
    end

    # Open a session with the app's MySQL client. No default database, so this
    # session can drop and create slots. The gem does not depend on the client.
    #
    # @param config_hash [Hash]
    # @param base [String] test database name, named in the error if this fails.
    # @return [Mysql2::Client, Trilogy]
    def self.open_mysql_connection(config_hash, base)
      adapter = config_hash[:adapter].to_s
      opts = mysql_client_options(config_hash)
      if adapter == "trilogy"
        raise "could not provision #{base}: the app's trilogy client is not loaded" unless defined?(Trilogy)

        Trilogy.new(opts)
      else
        raise "could not provision #{base}: the app's mysql2 client is not loaded" unless defined?(Mysql2::Client)

        Mysql2::Client.new(opts)
      end
    rescue StandardError => e
      raise e if e.message.start_with?("could not provision ")

      raise "could not provision #{base}: #{e.message}"
    end

    # Connection options shared by mysql2 and trilogy. The database key is left
    # out so the session is not tied to the test database.
    #
    # @param config_hash [Hash]
    # @return [Hash]
    def self.mysql_client_options(config_hash)
      opts = {}
      host = config_hash[:host].to_s
      opts[:host] = host unless host.empty?
      port = config_hash[:port]
      opts[:port] = Integer(port) if port && !port.to_s.empty?
      user = config_hash[:username] || config_hash[:user]
      opts[:username] = user.to_s if user && !user.to_s.empty?
      password = config_hash[:password]
      opts[:password] = password.to_s unless password.nil?
      # `:encoding` is an ActiveRecord key. mysql2 and trilogy do not share it.
      # Row copy runs in the server, so the client charset does not change it.
      opts
    end

    # Take a shared name, or every name when `shared` is false. A miss releases
    # any names this call already took.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @param shared [Boolean]
    # @return [Boolean]
    def self.try_mysql_lock(conn, base, shared:)
      held = []
      mysql_lock_names(base).each do |name|
        if mysql_get_lock(conn, name)
          held << name
          if shared
            @mysql_held_locks = held
            return true
          end
        elsif shared
          next
        else
          held.each { |got| mysql_release_lock(conn, got) }
          @mysql_held_locks = []
          return false
        end
      end
      return false if shared

      @mysql_held_locks = held
      true
    end

    # Release the GET_LOCK names this session took for the current run.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @return [void]
    def self.release_mysql_lock(conn)
      Array(@mysql_held_locks).each { |name| mysql_release_lock(conn, name) }
      @mysql_held_locks = []
      nil
    end

    # One GET_LOCK name per holder. The digest keeps the name inside 64 characters
    # for any base database name. Slot 63 is the last name.
    #
    # @param base [String]
    # @return [Array<String>]
    def self.mysql_lock_names(base)
      digest = Digest::SHA256.hexdigest("mutineer-run:#{base}")[0, 16]
      (0...MYSQL_LOCK_SLOTS).map { |slot| "m:#{digest}:#{slot}" }
    end

    # @param conn [Mysql2::Client, Trilogy]
    # @param name [String]
    # @return [Boolean]
    def self.mysql_get_lock(conn, name)
      rows = mysql_rows(conn, "SELECT GET_LOCK(#{mysql_quote_string(conn, name)}, 0) AS got")
      rows.dig(0, "got").to_i == 1
    end

    # @param conn [Mysql2::Client, Trilogy]
    # @param name [String]
    # @return [void]
    def self.mysql_release_lock(conn, name)
      mysql_exec(conn, "SELECT RELEASE_LOCK(#{mysql_quote_string(conn, name)})")
    end

    # Drop and create `name`. The caller has already checked {owned_database?}.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param name [String]
    # @return [void]
    def self.recreate_mysql_database(conn, name)
      quoted = quote_mysql_ident(name)
      mysql_exec(conn, "DROP DATABASE IF EXISTS #{quoted}")
      mysql_exec(conn, "CREATE DATABASE #{quoted} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
    end

    # Load `schema.rb` or `structure.sql` into the empty slot with the app's
    # DatabaseTasks. A missing file leaves the slot empty so the row copy can
    # still clone tables that exist only on the test database.
    #
    # @param base_hash [Hash] symbol-keyed config for the test database.
    # @param name [String] worker database name.
    # @param base [String] test database name, used in the failure text.
    # @return [void]
    def self.load_mysql_schema(base_hash, name, base)
      return unless defined?(ActiveRecord::Tasks::DatabaseTasks)

      slot_hash = base_hash.merge(database: name)
      ActiveRecord::Base.establish_connection(slot_hash)
      db_config = mysql_db_config(slot_hash)
      format = current_schema_format
      file = mysql_schema_file(db_config, format)
      return if file.nil?

      ActiveRecord::Tasks::DatabaseTasks.load_schema(db_config, format, file)
    rescue StandardError => e
      raise e if provision_wrapped?(e)

      raise provision_failure(base, name, e.message)
    end

    # A database config whose name is the slot, so DatabaseTasks loads into that
    # database and not the test database.
    #
    # @param slot_hash [Hash]
    # @return [ActiveRecord::DatabaseConfigurations::HashConfig]
    def self.mysql_db_config(slot_hash)
      env = ENV["RAILS_ENV"].to_s
      env = "test" if env.empty?
      ActiveRecord::DatabaseConfigurations::HashConfig.new(env, "primary", slot_hash)
    end

    # Schema format the booted app is using.
    #
    # @return [Symbol]
    def self.current_schema_format
      if ActiveRecord.respond_to?(:schema_format)
        ActiveRecord.schema_format
      else
        ActiveRecord::Base.schema_format
      end
    end

    # Absolute path of the schema file for `format`, or nil when it is absent.
    # DatabaseTasks aborts the process when the file is missing, so the caller
    # skips the load instead.
    #
    # @param db_config [ActiveRecord::DatabaseConfigurations::HashConfig]
    # @param format [Symbol]
    # @return [String, nil]
    def self.mysql_schema_file(db_config, format)
      path = ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(db_config, format)
      path if path && File.exist?(path)
    end

    # Copy every base table from `base` into `dest`. Foreign key checks are off.
    # Generated columns are left out of the INSERT list. A table the schema load
    # did not create is cloned with CREATE TABLE ... LIKE first.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @param dest [String]
    # @return [void]
    def self.copy_mysql_rows(conn, base, dest)
      mysql_exec(conn, "SET FOREIGN_KEY_CHECKS = 0")
      tables = mysql_rows(conn, <<~SQL)
        SELECT TABLE_NAME AS table_name
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = #{mysql_quote_string(conn, base)}
          AND TABLE_TYPE = 'BASE TABLE'
      SQL
      tables.each do |row|
        table = row["table_name"].to_s
        next if table.empty?

        ensure_mysql_table(conn, base, dest, table)
        columns = copyable_mysql_columns(conn, base, table)
        next if columns.empty?

        dest_table = "#{quote_mysql_ident(dest)}.#{quote_mysql_ident(table)}"
        base_table = "#{quote_mysql_ident(base)}.#{quote_mysql_ident(table)}"
        listed = columns.map { |column| quote_mysql_ident(column) }.join(", ")
        mysql_exec(conn, "DELETE FROM #{dest_table}")
        mysql_exec(conn, "INSERT INTO #{dest_table} (#{listed}) SELECT #{listed} FROM #{base_table}")
      end
    ensure
      begin
        mysql_exec(conn, "SET FOREIGN_KEY_CHECKS = 1")
      rescue StandardError
        nil
      end
    end

    # Create `table` on `dest` when the schema load did not. LIKE copies columns,
    # including generated columns, and does not copy foreign keys.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @param dest [String]
    # @param table [String]
    # @return [void]
    def self.ensure_mysql_table(conn, base, dest, table)
      rows = mysql_rows(conn, <<~SQL)
        SELECT TABLE_NAME AS table_name
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = #{mysql_quote_string(conn, dest)}
          AND TABLE_NAME = #{mysql_quote_string(conn, table)}
          AND TABLE_TYPE = 'BASE TABLE'
      SQL
      return unless rows.empty?

      mysql_exec(conn, "CREATE TABLE #{quote_mysql_ident(dest)}.#{quote_mysql_ident(table)} LIKE #{quote_mysql_ident(base)}.#{quote_mysql_ident(table)}")
    end

    # Column names that an INSERT may set. Stored and virtual generated columns
    # are omitted. Expression defaults stay, because they are real columns.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @param table [String]
    # @return [Array<String>]
    def self.copyable_mysql_columns(conn, base, table)
      rows = mysql_rows(conn, <<~SQL)
        SELECT COLUMN_NAME AS column_name, EXTRA AS extra
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = #{mysql_quote_string(conn, base)}
          AND TABLE_NAME = #{mysql_quote_string(conn, table)}
        ORDER BY ORDINAL_POSITION
      SQL
      rows.filter_map do |row|
        name = row["column_name"].to_s
        next if name.empty?
        next if row["extra"].to_s.match?(/VIRTUAL GENERATED|STORED GENERATED/i)

        name
      end
    end

    # Run a statement that does not need its result rows.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param sql [String]
    # @return [void]
    def self.mysql_exec(conn, sql)
      conn.query(sql)
      nil
    end

    # Result rows as string-keyed hashes. mysql2 yields hashes from `each`.
    # trilogy yields them from `each_hash`. Keys are downcased so aliases match.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param sql [String]
    # @return [Array<Hash>]
    def self.mysql_rows(conn, sql)
      result = conn.query(sql)
      return [] if result.nil?

      rows = []
      if result.respond_to?(:each_hash)
        result.each_hash { |row| rows << stringify_mysql_row(row) }
      else
        result.each(as: :hash) { |row| rows << stringify_mysql_row(row) }
      end
      rows
    end

    # @param row [Hash]
    # @return [Hash]
    def self.stringify_mysql_row(row)
      row.to_h.transform_keys { |key| key.to_s.downcase }
    end

    # Quote a string for a SQL literal with the client the app loaded.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param value [String]
    # @return [String]
    def self.mysql_quote_string(conn, value)
      "'#{conn.escape(value.to_s)}'"
    end

    # Quote a MySQL identifier. Backticks inside the name are doubled.
    #
    # @param name [String]
    # @return [String]
    def self.quote_mysql_ident(name)
      raise ArgumentError, "database name is empty" if name.nil? || name.empty?
      raise ArgumentError, "database name contains a null" if name.include?("\0")

      "`#{name.to_s.gsub('`', '``')}`"
    end

    # True when `error` is already a provision failure this module raised.
    #
    # @param error [StandardError]
    # @return [Boolean]
    def self.provision_wrapped?(error)
      message = error.message
      message.start_with?("could not provision", "another Mutineer run", "refusing to drop")
    end
  end
end
