# frozen_string_literal: true

require "digest"
require "uri"

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
    # MySQL rejects a database name longer than this many bytes. The shortening
    # rule matches Postgres. A byte limit stays inside the 64-character limit.
    MYSQL_NAME_LIMIT = 64
    # How many worker daemons can hold a lock at once. MySQL GET_LOCK is
    # exclusive, so each daemon takes one name from this pool. A separate guard
    # name covers the handoff and is not one of these slots.
    MYSQL_LOCK_SLOTS = 256
    # Actions information_schema may report for a foreign key. Anything else is
    # rejected so a bad row cannot change the ALTER TABLE statement.
    MYSQL_REFERENTIAL_ACTIONS = ["CASCADE", "SET NULL", "SET DEFAULT", "RESTRICT", "NO ACTION"].freeze
    # TLS and timeout keys from the app's MySQL config that reach the
    # maintenance client unchanged. ActiveRecord passes them to the client the
    # same way. The first group is mysql2's, the second trilogy's. Each client
    # ignores the other's keys.
    MYSQL_CLIENT_KEYS = %i[
      connect_timeout read_timeout write_timeout
      ssl_mode sslkey sslcert sslca sslcapath sslcipher sslverify get_server_public_key
      ssl ssl_ca ssl_capath ssl_cert ssl_key ssl_cipher ssl_crl ssl_crlpath
      tls_ciphersuites tls_min_version tls_max_version
    ].freeze
    # Infix that keeps a worker database off Rails' own `<base>-<n>` names.
    WORKER_NAME_MARK = "-mutineer-"
    # Database we connect to while the test database is a template. Advisory
    # locks are per database, so every run must take them here, not on a slot.
    MAINTENANCE_DATABASE = "postgres"
    # Server catalogs a worker copy must never drop, even if a name bug
    # produced one of them.
    RESERVED_DATABASES = %w[postgres template0 template1].freeze
    # Rails keys copied onto the maintenance `PG::Connection`. `database` is
    # not here: that session always uses {MAINTENANCE_DATABASE}. `username` is
    # Rails' spelling of libpq `user`. Anything else (adapter, variables,
    # schema_search_path) is a Rails setting and would make libpq reject the
    # connection.
    LIBPQ_CONNECTION_KEYS = {
      host: :host,
      hostaddr: :hostaddr,
      port: :port,
      user: :user,
      username: :user,
      password: :password,
      service: :service,
      sslmode: :sslmode,
      sslcert: :sslcert,
      sslkey: :sslkey,
      sslrootcert: :sslrootcert,
      sslcrl: :sslcrl,
      sslcompression: :sslcompression,
      ssl_min_protocol_version: :ssl_min_protocol_version,
      ssl_max_protocol_version: :ssl_max_protocol_version,
      connect_timeout: :connect_timeout,
      client_encoding: :client_encoding,
      options: :options,
      application_name: :application_name,
      fallback_application_name: :fallback_application_name,
      keepalives: :keepalives,
      keepalives_idle: :keepalives_idle,
      keepalives_interval: :keepalives_interval,
      keepalives_count: :keepalives_count,
      channel_binding: :channel_binding,
      gssencmode: :gssencmode,
      krbsrvname: :krbsrvname,
      gsslib: :gsslib,
      requiressl: :requiressl,
      target_session_attrs: :target_session_attrs
    }.freeze

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
    # `limit` bytes, the base is shortened on a character boundary and a hash
    # of the full base is added so two slots, and two long bases that share a
    # prefix, stay distinct.
    #
    # @param base [String] the test database name.
    # @param slot [Integer] the worker slot index.
    # @param limit [Integer] maximum name length in bytes.
    # @return [String] a name of at most `limit` bytes, or the hash suffix
    #   alone when that suffix itself exceeds the limit.
    def self.worker_database_name(base, slot, limit)
      suffix = "#{WORKER_NAME_MARK}#{slot}"
      full = "#{base}#{suffix}"
      return full if full.bytesize <= limit

      hash = Digest::SHA256.hexdigest(base)[0, 8]
      tail = "-#{hash}#{suffix}"
      room = limit - tail.bytesize
      "#{utf8_prefix(base, room)}#{tail}"
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

    # Leading characters of `text` that fit in `max_bytes`. Stops before a
    # character that would cross the limit, so a multibyte name stays valid
    # text. PostgreSQL and MySQL count identifier length in bytes.
    #
    # @param text [String]
    # @param max_bytes [Integer]
    # @return [String]
    def self.utf8_prefix(text, max_bytes)
      return "" if max_bytes <= 0

      source = text.to_s
      return source if source.bytesize <= max_bytes

      kept = +""
      source.each_char do |char|
        break if kept.bytesize + char.bytesize > max_bytes

        kept << char
      end
      kept
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

    # True when `name` is a database this tool may drop. It must be the exact
    # name {postgres_worker_database} would build for `base` and the slot
    # written at the end of `name`. The source database, a server catalog, and
    # any other name are refused.
    #
    # @param base [String] the test database name.
    # @param name [String] a database name we might drop.
    # @return [Boolean]
    def self.worker_database_name?(base, name)
      return false if base.nil? || name.nil?

      text = name.to_s
      source = base.to_s
      return false if text.empty? || text == source
      return false if RESERVED_DATABASES.include?(text)

      slot = text[/#{Regexp.escape(WORKER_NAME_MARK)}(\d+)\z/, 1]
      return false unless slot

      postgres_worker_database(source, Integer(slot, 10)) == text
    end

    # Build the AR connection config for one worker from the app's current
    # test config. SQLite, Postgres, and MySQL (mysql2 or trilogy) get a
    # per-worker database name. Anything else raises.
    #
    # @param worker [Integer] the worker slot index.
    # @return [Hash] a symbol-keyed AR configuration hash for the worker database.
    # @raise [NotImplementedError] when the adapter has no worker database yet, or the database is in-memory.
    def self.worker_db_config(worker)
      per_worker_config(routing_config_hash, worker)
    end

    # Config used to name a worker database. MySQL schema load points
    # ActiveRecord at the last slot. Coverage forks must keep the original test
    # database, or the next name is nested and was never created.
    #
    # @return [Hash]
    def self.routing_config_hash
      @mysql_base_config || current_config_hash
    end

    # Remember the test database config before schema load switches the connection.
    #
    # @param config_hash [Hash]
    # @return [void]
    def self.remember_mysql_base_config(config_hash)
      @mysql_base_config = config_hash.transform_keys(&:to_sym)
      nil
    end

    # Drop the remembered MySQL test config. The next route reads ActiveRecord again.
    #
    # @return [void]
    def self.forget_mysql_base_config
      @mysql_base_config = nil
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
      adapter  = hash[:adapter].to_s
      database = hash[:database].to_s
      if database.empty? && postgres_adapter?(adapter)
        database = database_name_from_url(hash[:url])
      end
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
    # SQLite checks configured pools; the file is copied on first use. Postgres drops and
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
      verify_configured_pools!
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
      base = source_database_name!(hash)
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

    # The database config names the test environment declares, the primary
    # (the config `ActiveRecord::Base` uses), and the names each worker copies.
    # On SQLite (Rails 7.1 or later), each worker copies every file database.
    # On Postgres and MySQL, it copies only the primary. The tool counts the names that are neither
    # copied nor in `shared_databases`: any such name means one worker.
    #
    # A config with `database_tasks: false` counts: workers would share it like
    # any other. A replica does not, as before: it reads another config's database.
    # No rescue: a failure must reach the tool, which then keeps one worker.
    #
    # @return [Hash{String => Object}] "names" (Array<String>), "primary"
    #   (String), and "copied" (Array<String>).
    def self.database_names
      configs = test_configs.reject(&:replica?)
      primary = ActiveRecord::Base.connection_db_config.name
      copied  = [primary]
      # Keep Rails 7.0's conservative one-worker policy for several databases.
      if sqlite_adapter?(current_adapter) && ActiveRecord.version >= Gem::Version.new("7.1")
        copied |= configs.select { |c| sqlite_file_config?(c) }.map(&:name)
      end
      { "names" => configs.map(&:name), "primary" => primary, "copied" => copied }
    end

    # The test environment's database configs, hidden ones and replicas included.
    #
    # @return [Array<ActiveRecord::DatabaseConfigurations::DatabaseConfig>]
    def self.test_configs
      env = ENV["RAILS_ENV"].to_s
      env = "test" if env.empty?
      ActiveRecord::Base.configurations.configs_for(env_name: env, include_hidden: true)
    end

    # Child-side (after fork): route this process's ActiveRecord at the worker's
    # own database and confirm it is reachable, so a routing failure reads as
    # `error` rather than a false verdict.
    #
    # SQLite gives the worker its own copy of every test database file on
    # Rails 7.1 or later (see {route_sqlite_configs}). Rails 7.0 copies only
    # the primary file group and keeps other files on their serial base paths.
    # With `seed: true` it copies each base file first, then loads the primary's
    # `schema.rb` only when the copy differs from that file, and each other
    # database's schema file only when its copy is out of date. Postgres and
    # MySQL ignore `seed`, the schema path, and `shared`: the slot was copied at
    # {provision}, and loading `schema.rb` again would drop those rows.
    #
    # @param worker [Integer] the worker slot index.
    # @param schema_path [String, nil] absolute path to `db/schema.rb`, or nil to skip.
    # @param seed [Boolean] copy each base SQLite file into its worker file first.
    # @param shared [Array<String>] SQLite config names the workers share
    #   (`shared_databases`). They keep the base file.
    # @return [void]
    # @raise [NotImplementedError] when the primary is not a SQLite file (in memory,
    #   a `file:` URI, or blank): {route_sqlite_configs} could not copy it.
    # @raise [RuntimeError] when a pool still points at a base file (see {verify_routing!}).
    def self.after_fork(worker, schema_path = nil, seed: false, shared: [])
      @routing = nil
      return unless available?

      forget_lock_connection_after_fork!
      if postgres_adapter?(current_adapter) || mysql_adapter?(current_adapter)
        @routing = [[], test_configs.select { |config| sqlite_file_config?(config) }.map { |config| sqlite_file(config) }]
        connect(worker)
        verify_routing!(*@routing)
        verify_connection!
        return
      end

      primary = ActiveRecord::Base.connection_db_config
      unless sqlite_file_config?(primary)
        raise NotImplementedError,
              "worker-DB isolation needs a SQLite database file (got #{primary.database.inspect})."
      end

      @routing = route_sqlite_configs(worker, seed: seed, shared: shared, primary: sqlite_file(primary),
                                      copy_all: ActiveRecord.version >= Gem::Version.new("7.1"))
      verify_routing!(*@routing)
      load_schema(schema_path) if schema_path && !schema_current?(schema_path)
      load_other_schemas(primary, routed: @routing.first) if seed
      verify_routing!(*@routing)
      verify_connection!
    end

    # Run the routing check again after the tests. A pool that a test or an
    # autoloaded model opened after {after_fork} (an inline
    # `establish_connection` hash) then also fails the mutant with `error`.
    # Also checks SQLite pools when the primary uses Postgres or MySQL.
    #
    # @return [void]
    # @raise [RuntimeError] when a pool points at a base file every worker shares.
    def self.recheck_routing!
      verify_routing!(*@routing) if @routing
    end

    # Check boot-registered SQLite pools before provisioning or coverage clean
    # checks. Declared files may still use their base paths in this parent.
    # An unsupported pool must report its routing cause before a cached clean
    # check can mistake the setup exception for a test failure.
    #
    # @return [void]
    # @raise [RuntimeError] when a SQLite pool cannot be isolated.
    def self.verify_configured_pools!
      files = test_configs.select { |config| sqlite_file_config?(config) }.map { |config| sqlite_file(config) }
      verify_routing!([], files)
    end

    # Point every SQLite file config of the test environment at this worker's
    # copy. Each DatabaseConfig is rewritten in place (`_database=`), so every
    # pool resolved from `configurations` follows: `ActiveRecord::Base` and each
    # `connects_to` class. Rails discards inherited pools after a fork, and a
    # new pool opens connections from its config's current hash. Runs only in
    # a fork child, so the daemon keeps the base names for the next fork.
    #
    # A replica that names the same file as its primary gets the same worker
    # file. A config named in `shared`, and any config on the same file, keeps
    # the base file, except the primary's file: every worker always copies it.
    # Shared aliases use one base path so the shared-connection check sees them.
    #
    # @param worker [Integer] the worker slot index.
    # @param seed [Boolean] copy each base file into its worker file first.
    # @param shared [Array<String>] config names that keep the base file.
    # @param primary [String, nil] the primary's absolute file, never kept.
    # @param copy_all [Boolean] copy independent files; false keeps the Rails 7.0 serial fallback.
    # @return [Array(Array<String>, Array<String>)] the worker files, and the
    #   base files kept for `shared` or the Rails 7.0 serial fallback.
    # @raise [RuntimeError] when a worker file aliases a base file or another worker file.
    def self.route_sqlite_configs(worker, seed:, shared:, primary: nil, copy_all: true)
      configs = test_configs.select { |c| sqlite_file_config?(c) }
      groups = configs.group_by { |config| database_file_identity(sqlite_file(config)) }
      primary_key = database_file_identity(primary) if primary
      routed = {}
      kept = {}
      groups.each do |identity, aliases|
        shared_config = if identity != primary_key
                          copy_all ? aliases.find { |config| shared.include?(config.name) } : aliases.first
                        end
        if shared_config
          kept[identity] = sqlite_file(shared_config)
        else
          routed[identity] = worker_database_path(sqlite_file(aliases.first), worker)
        end
      end

      # Validate every destination before any backup or deletion can touch it.
      destinations = {}
      routed.each_value do |file|
        identity = database_file_identity(file)
        if groups.key?(identity)
          raise "worker file #{file} is also the base file of a test database; rename one of them"
        end
        if destinations.key?(identity)
          raise "worker files #{destinations.fetch(identity)} and #{file} use the same file; rename one of them"
        end
        destinations[identity] = file
      end
      routed.each do |identity, file|
        seed_worker_file(sqlite_file(groups.fetch(identity).first), file) if seed
      end
      groups.each do |identity, aliases|
        file = routed[identity] || kept.fetch(identity)
        aliases.each { |config| config._database = file }
      end
      [routed.values, kept.values]
    end

    # Identity of an existing file, including hard links. A missing file uses
    # its canonical path so aliases are detected before schema loading creates it.
    #
    # @param file [String] absolute database path.
    # @return [Array<Symbol, Integer, String>]
    def self.database_file_identity(file)
      stat = File.stat(file)
      [:file, stat.dev, stat.ino]
    rescue Errno::ENOENT
      [:path, canonical_database_path(file)]
    end

    # Resolve existing symlinks, preserving missing path components after the
    # nearest existing parent directory.
    #
    # @param file [String] absolute database path.
    # @return [String]
    def self.canonical_database_path(file)
      File.realdirpath(file)
    rescue Errno::ENOENT
      File.join(canonical_database_path(File.dirname(file)), File.basename(file))
    end

    # Copy `base` into `file`. When the base file does not exist yet (Rails
    # creates a SQLite file on first connect), delete the worker file instead,
    # so the worker starts from an empty database, not an old run's rows.
    #
    # @param base [String] the base database file.
    # @param file [String] the worker database file.
    # @return [void]
    def self.seed_worker_file(base, file)
      if File.exist?(base)
        seed_from(base, file)
      else
        ["", "-wal", "-shm"].each { |suffix| File.delete("#{file}#{suffix}") if File.exist?("#{file}#{suffix}") }
      end
    end

    # Load one schema for each SQLite file other than the primary file
    # when its worker copy is out of date. Rails' DatabaseTasks picks each
    # config's own file (`db/<name>_schema.rb` by default) and skips a config
    # with no file. Physical aliases must agree on their existing schema dumps;
    # conflicting dumps raise before any secondary schema loads. Shared base
    # files are never loaded. No purge: the schema
    # loads over the copy, so tables a --require file wrote at boot survive
    # (#222). Rails 7.1 names its helper for connections, not pools. Older
    # versions with neither helper use the copy as it is.
    #
    # @param primary [ActiveRecord::DatabaseConfigurations::DatabaseConfig] the
    #   config `ActiveRecord::Base` uses. {load_schema} covers it.
    # @param routed [Array<String>] the worker files, excluding shared bases.
    # @raise [RuntimeError] when physical aliases use conflicting schema dumps.
    # @return [void]
    def self.load_other_schemas(primary, routed:)
      tasks = ActiveRecord::Tasks::DatabaseTasks
      helper = %i[with_temporary_pool_for_each with_temporary_connection_for_each].find { |name| tasks.respond_to?(name) }
      return unless helper

      groups = test_configs.select do |config|
        !config.replica? && config.database_tasks? && sqlite_file_config?(config) && routed.include?(sqlite_file(config))
      end.group_by { |config| database_file_identity(sqlite_file(config)) }
      groups.delete(database_file_identity(sqlite_file(primary)))
      # Validate all groups before loading any schema, so a later conflict
      # cannot leave earlier secondary copies changed.
      schemas = groups.values.filter_map do |configs|
        dumps = configs.filter_map do |config|
          path = tasks.schema_dump_path(config)
          [config, path] if path && File.file?(path)
        end
        if dumps.map { |_config, path| Digest::SHA1.file(path).hexdigest }.uniq.size > 1
          raise "SQLite aliases #{configs.map(&:name).join(', ')} use conflicting schema dumps; " \
                "configure one schema for their shared file"
        end
        dumps.first&.first
      end
      schemas.each do |config|
        tasks.public_send(helper, env: config.env_name, name: config.name) do
          tasks.load_schema(config) unless tasks.schema_up_to_date?(config)
        end
      end
    end

    # Check every pool on a SQLite file, then confirm each routed pool's
    # connection really opened the worker file. A pool built from an inline
    # `establish_connection` hash is not in `configurations`, so
    # {route_sqlite_configs} cannot rewrite it: it would
    # still use the base file that every worker shares. That raises here, and
    # the mutant scores `error`. Shared pools get no round-trip, so the
    # `shared_databases` check does not see a connection the tool opened.
    #
    # @param routed [Array<String>] the worker files.
    # @param kept [Array<String>] the base files kept for shared or serial use.
    # @return [void]
    # @raise [RuntimeError] when a pool points at a file that is neither.
    def self.verify_routing!(routed, kept)
      role = ActiveRecord.version < Gem::Version.new("7.1") ? nil : :all
      ActiveRecord::Base.connection_handler.connection_pool_list(role).each do |pool|
        config = pool.db_config
        if sqlite_adapter?(config.adapter.to_s) && config.database.to_s.start_with?("file:")
          raise "#{config.name} uses a SQLite file: URI, which cannot be copied per worker. " \
                "Use a plain database file path in config/database.yml."
        end
        if sqlite_adapter?(config.adapter.to_s) && !sqlite_file_config?(config) && !test_configs.include?(config)
          raise "#{config.name} uses an inline SQLite database #{config.database.inspect}, which cannot be copied per worker. " \
                "Use a plain database file path in config/database.yml."
        end
        next unless sqlite_file_config?(config)

        file = sqlite_file(config)
        next if kept.include?(file)
        unless routed.include?(file)
          raise "#{config.name} still uses #{file}, which every worker shares. " \
                "Mutineer copies only databases in config/database.yml, not an inline establish_connection hash."
        end

        # Ask SQLite which file the connection opened: a connection opened
        # before the config was rewritten would still be on the base file.
        opened = pool.with_connection { |conn| conn.select_value("SELECT file FROM pragma_database_list WHERE name = 'main'") }
        raise "#{config.name} is connected to #{opened}, not its worker file #{file}" unless File.identical?(opened.to_s, file)
      end
    end

    # True for a SQLite config with a database file: not `:memory:`, not a
    # `file:` URI, not blank.
    #
    # @param config [ActiveRecord::DatabaseConfigurations::DatabaseConfig]
    # @return [Boolean]
    def self.sqlite_file_config?(config)
      database = config.database.to_s
      sqlite_adapter?(config.adapter.to_s) && !database.empty? && database != ":memory:" && !database.start_with?("file:")
    end

    # Absolute path of a SQLite config's file, resolved as the Rails adapter
    # does: against `Rails.root` when it is set.
    #
    # @param config [ActiveRecord::DatabaseConfigurations::DatabaseConfig]
    # @return [String]
    def self.sqlite_file(config)
      root = defined?(Rails.root) && Rails.root
      root ? File.expand_path(config.database, root.to_s) : File.expand_path(config.database)
    end

    # Copy a base SQLite file into a worker file with the SQLite online backup
    # API: one consistent snapshot of the committed data (WAL included) that
    # replaces whatever the worker file held (an earlier run, or a copy a
    # timeout interrupted).
    #
    # @param base_file [String] the base database file.
    # @param dest_file [String] the worker database file.
    # @return [void]
    def self.seed_from(base_file, dest_file)
      codes  = SQLite3::Constants::ErrorCode
      source = SQLite3::Database.new(base_file, readonly: true)
      source.busy_timeout = 5000
      dest   = SQLite3::Database.new(dest_file)
      backup = SQLite3::Backup.new(dest, "main", source, "main")
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
      dest&.close
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

    # Names from `shared` whose database a connected pool uses in this
    # process. Run in a fork after its tests: a name here means a test used a
    # database that parallel workers share, so the verdict cannot be trusted.
    # A pool counts when its config has a shared name, or names the same
    # database as a shared config (a replica of it, say). Transactional tests
    # connect every registered writing pool, so a pool registered for a shared
    # database shows up here after any test.
    #
    # No rescue: a failed check must raise (scored `error`), never read as clean.
    # ponytail: a snapshot after the run; a pool the test removes
    # (`remove_connection`) is missed. Upgrade path: watch `sql.active_record`.
    #
    # @param shared [Array<String>] database config names in `shared_databases`.
    # @return [Array<String>]
    def self.touched_shared_databases(shared)
      return [] if shared.empty? || !available?

      copied = Array(@routing&.first).map { |file| database_file_identity(file) }
      configs = test_configs.select { |config| shared.include?(config.name) && config.database }
      configs.reject! { |config| sqlite_file_config?(config) && copied.include?(database_file_identity(sqlite_file(config))) }
      shared_names = configs.map(&:name)
      return [] if shared_names.empty?

      # Rails 7.0 reads `:all` below as a role name and lists no pool, so the
      # check would always pass. Fail every mutant instead of trusting it.
      raise "shared_databases needs Rails 7.1 or later" if ActiveRecord.version < Gem::Version.new("7.1")

      database_key = lambda do |config|
        sqlite_file_config?(config) ? database_file_identity(sqlite_file(config)) : config.database
      end
      by_database = {}
      configs.each { |config| by_database[database_key.call(config)] = config.name }
      pools = ActiveRecord::Base.connection_handler.connection_pool_list(:all).select(&:connected?)
      names = pools.map do |pool|
        config = pool.db_config
        shared_names.include?(config.name) ? config.name : by_database[database_key.call(config)]
      end
      names.compact.uniq
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
      base = source_database_name!(hash)
      conn = open_maintenance_connection(hash, base)
      unless try_lock(conn, base, shared: false)
        conn.close
        raise "another Mutineer run is using #{base}"
      end

      begin
        disconnect_app!
        count.times do |slot|
          name = postgres_worker_database(base, slot)
          recreate_from_template(conn, name, base)
        end
      rescue StandardError => e
        unlock(conn, base)
        conn.close
        raise provision_wrapped?(e) ? e : provision_failure(base, base, e.message)
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
    # Endpoint options from the Rails config, including `service` and `url`, are
    # kept. Only the database name changes, to {MAINTENANCE_DATABASE}.
    #
    # @param config_hash [Hash]
    # @param base [String] test database name, named in the error if this fails.
    # @return [PG::Connection]
    def self.open_maintenance_connection(config_hash, base)
      unless defined?(PG::Connection)
        raise "could not provision #{base}: the app's pg client is not loaded"
      end

      PG::Connection.open(maintenance_connection_options(config_hash))
    rescue StandardError => e
      raise e if e.message.start_with?("could not provision")

      raise "could not provision #{base}: #{e.message}"
    end

    # libpq options for the maintenance session. A Rails `url:` fills anything
    # the hash does not set itself. Explicit keys win. `dbname` is always
    # {MAINTENANCE_DATABASE}, never the test database and never a name taken
    # from the URL path.
    #
    # @param config_hash [Hash] symbol or string keys, as Rails stores them.
    # @return [Hash] symbol keys for `PG::Connection.open`.
    # @raise [RuntimeError] when `url:` is present and is not a Postgres URL.
    def self.maintenance_connection_options(config_hash)
      hash = config_hash.transform_keys(&:to_sym)
      opts = options_from_database_url(hash[:url])
      opts.delete(:database)
      LIBPQ_CONNECTION_KEYS.each do |config_key, pg_key|
        next unless hash.key?(config_key)

        value = hash[config_key]
        next if blank_option?(value)

        opts[pg_key] = value
      end
      opts[:dbname] = MAINTENANCE_DATABASE
      opts
    end

    # The test database this run copies from. `database:` wins. A Postgres URL
    # supplies the name when the hash has none. A `service:` entry does not
    # carry the name, so that shape fails here instead of guessing.
    #
    # @param config_hash [Hash]
    # @return [String]
    # @raise [RuntimeError] when no database name is available.
    def self.source_database_name!(config_hash)
      hash = config_hash.transform_keys(&:to_sym)
      name = hash[:database].to_s
      name = database_name_from_url(hash[:url]) if name.empty?
      return name unless name.empty?

      raise "could not provision: the test database name is missing. " \
            "Set database: or use a URL that includes the database name."
    end

    # Database name from a postgres URL path, or "" when `url` is blank.
    #
    # @param url [String, nil]
    # @return [String]
    # @raise [RuntimeError] when `url` is present and is not a Postgres URL.
    def self.database_name_from_url(url)
      options_from_database_url(url)[:database].to_s
    end

    # Host, credentials, database name, and query options from a Rails `url:`.
    # Blank when `url` is blank. The database is returned under `:database`
    # so callers can separate it from the maintenance `dbname`.
    #
    # @param url [String, nil]
    # @return [Hash]
    # @raise [RuntimeError] when `url` is present and is not a Postgres URL.
    def self.options_from_database_url(url)
      return {} if blank_option?(url)

      uri = URI.parse(url.to_s)
      scheme = uri.scheme.to_s.downcase
      unless scheme == "postgres" || scheme == "postgresql"
        raise "could not provision: the database URL must start with postgres:// or postgresql://"
      end

      opts = {}
      host = uri.host
      opts[:host] = host if host && !host.empty?
      opts[:port] = uri.port if uri.port
      user = decode_uri_component(uri.user)
      opts[:user] = user if user && !user.empty?
      password = decode_uri_component(uri.password)
      opts[:password] = password if password && !password.empty?
      database = uri.path.to_s.sub(%r{\A/}, "")
      database = decode_uri_component(database) unless database.empty?
      opts[:database] = database if database && !database.empty?
      URI.decode_www_form(uri.query.to_s).each do |key, value|
        pg_key = LIBPQ_CONNECTION_KEYS[key.to_sym]
        next unless pg_key
        next if blank_option?(value)

        opts[pg_key] = value
      end
      opts
    rescue URI::InvalidURIError, URI::InvalidComponentError, ArgumentError
      # The parser's message repeats the URL, password included. `cause: nil`
      # keeps Ruby from printing that original error under this one.
      raise "could not provision: the database URL is not valid. " \
            "The URL is not shown because it can contain a password. " \
            "Check each part of DATABASE_URL or url: in config/database.yml. " \
            "Percent-encode the user name, password and database name. Encode each " \
            "character that is not an ASCII letter, a digit, -, ., _ or ~. " \
            "For example, write % as %25, @ as %40 and a space as %20.", cause: nil
    end

    # Percent-decode one URL component. Nil when `text` is blank.
    #
    # @param text [String, nil]
    # @return [String, nil]
    def self.decode_uri_component(text)
      return if blank_option?(text)

      # `unescape` keeps a literal `+`. The form decoder would turn it into a space.
      # The daemon runs on the app's Ruby, which may be older than 3.4.
      URI::DEFAULT_PARSER.unescape(text.to_s)
    end

    # True for nil and empty strings. Numbers and false are present values.
    #
    # @param value [Object]
    # @return [Boolean]
    def self.blank_option?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
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
      unless worker_database_name?(base, name)
        raise "refusing to drop #{name}"
      end

      conn.exec("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = #{conn.escape_literal(name)} AND pid <> pg_backend_pid()")
      conn.exec("DROP DATABASE IF EXISTS #{quote_ident(name)}")
      conn.exec("CREATE DATABASE #{quote_ident(name)} TEMPLATE #{quote_ident(base)}")
    rescue StandardError => e
      raise e if e.message.start_with?("refusing to drop")

      raise provision_failure(base, name, e.message)
    end

    # Close every connection this process holds through ActiveRecord, so the
    # test database can be used as a Postgres template and a MySQL slot can be
    # dropped.
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
    # without sending a disconnect, so the parent's locks stay held.
    # Clearing the held-name list stops the child from sending RELEASE_LOCK
    # on that shared session.
    #
    # @return [void]
    def self.forget_lock_connection_after_fork!
      @mysql_held_locks = []
      conn = @lock_connection
      @lock_connection = nil
      return unless conn

      detach_inherited_connection(conn)
      ObjectSpace.undefine_finalizer(conn)
    end

    # Make a fork child's copy of the lock connection safe to free. The
    # client's free function runs at the child's next GC. Left as it is, that
    # sends QUIT (mysql2) or Terminate (pg) on the socket the parent shares,
    # so the server ends the parent's session and every lock it holds.
    # These are the steps ActiveRecord's adapters take in `discard!`.
    #
    # @param conn [Mysql2::Client, Trilogy, PG::Connection]
    # @return [void]
    def self.detach_inherited_connection(conn)
      if conn.respond_to?(:automatic_close=)
        conn.automatic_close = false # mysql2: GC drops only this process's fd
      elsif conn.respond_to?(:discard!)
        conn.discard! # trilogy: closes only this process's fd
      elsif conn.respond_to?(:socket_io)
        conn.socket_io.reopen(IO::NULL) # pg: Terminate goes to /dev/null
      end
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
    # rows from the test database. Holds the guard lock and every pool name
    # while copying, then keeps the guard lock. Pool names are released without
    # a gap so another run cannot drop the new databases. Worker daemons then
    # take one pool name each.
    #
    # @param count [Integer]
    # @return [void]
    # @raise [RuntimeError] when `count` exceeds {MYSQL_LOCK_SLOTS}, or another run holds the lock.
    def self.provision_mysql(count)
      if count > MYSQL_LOCK_SLOTS
        raise "MySQL worker databases support at most #{MYSQL_LOCK_SLOTS} workers"
      end

      hash = routing_config_hash
      remember_mysql_base_config(hash)
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
          begin
            recreate_mysql_database(conn, name, base)
            load_mysql_schema(hash, name, base)
            copy_mysql_rows(conn, base, name)
          rescue StandardError => e
            raise e if provision_wrapped?(e)

            raise provision_failure(base, name, e.message)
          end
        end
        raise "another Mutineer run is using #{base}" unless downgrade_mysql_lock_to_shared(conn, base)
      rescue StandardError => e
        release_held_mysql_locks(conn)
        conn.close
        raise e if provision_wrapped?(e)

        raise provision_failure(base, base, e.message)
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

    # Open a session with the app's MySQL client. It starts with no default
    # database, so it is not tied to the test database while it drops and
    # creates slots. {restore_mysql_triggers} later selects a slot. Every
    # other statement names its database. The gem does not depend on the client.
    #
    # @param config_hash [Hash]
    # @param base [String] test database name, named in the error if this fails.
    # @return [Mysql2::Client, Trilogy]
    def self.open_mysql_connection(config_hash, base)
      adapter = config_hash[:adapter].to_s
      opts = mysql_client_options(config_hash)
      if adapter == "trilogy"
        raise "could not provision #{base}: the app's trilogy client is not loaded" unless defined?(Trilogy)

        # Rails' adapter turns a `ssl_mode` name into the constant trilogy wants.
        if defined?(ActiveRecord::ConnectionAdapters::TrilogyAdapter)
          ActiveRecord::ConnectionAdapters::TrilogyAdapter.new_client(opts)
        else
          Trilogy.new(opts)
        end
      else
        raise "could not provision #{base}: the app's mysql2 client is not loaded" unless defined?(Mysql2::Client)

        Mysql2::Client.new(opts)
      end
    rescue StandardError => e
      raise e if e.message.start_with?("could not provision ")

      raise "could not provision #{base}: #{e.message}"
    end

    # Connection options shared by mysql2 and trilogy. The database key is left
    # out so the session is not tied to the test database. A socket wins over
    # host: trilogy ignores `socket` when `host` is set, and would then use its
    # compiled-in default instead of the app's socket. TLS and timeout keys in
    # {MYSQL_CLIENT_KEYS} are kept.
    #
    # @param config_hash [Hash]
    # @return [Hash]
    def self.mysql_client_options(config_hash)
      opts = {}
      socket = config_hash[:socket].to_s
      if socket.empty?
        host = config_hash[:host].to_s
        opts[:host] = host unless host.empty?
        port = config_hash[:port]
        opts[:port] = Integer(port) if port && !port.to_s.empty?
      else
        opts[:socket] = socket
      end
      user = config_hash[:username] || config_hash[:user]
      opts[:username] = user.to_s if user && !user.to_s.empty?
      password = config_hash[:password]
      opts[:password] = password.to_s unless password.nil?
      MYSQL_CLIENT_KEYS.each { |key| opts[key] = config_hash[key] unless config_hash[key].nil? }
      # `:encoding` is an ActiveRecord key. mysql2 and trilogy do not share it.
      # Row copy runs in the server, so the client charset does not change it.
      opts
    end

    # Take one pool name, or the guard plus every pool name when `shared` is
    # false. A miss releases any names this call already took.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @param shared [Boolean]
    # @return [Boolean]
    def self.try_mysql_lock(conn, base, shared:)
      return try_mysql_shared_lock(conn, base) if shared

      try_mysql_exclusive_lock(conn, base)
    end

    # Take the guard, then every pool name. The guard stays held across the
    # later downgrade so another run cannot start a copy in that gap.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @return [Boolean]
    def self.try_mysql_exclusive_lock(conn, base)
      guard = mysql_guard_lock_name(base)
      return false unless mysql_get_lock(conn, guard)

      held = [guard]
      mysql_lock_names(base).each do |name|
        if mysql_get_lock(conn, name)
          held << name
        else
          held.each { |got| mysql_release_lock(conn, got) }
          @mysql_held_locks = []
          return false
        end
      end
      @mysql_held_locks = held
      true
    end

    # Take the first free pool name. Does not take the guard, so worker daemons
    # can connect while the provisioning process still holds that guard.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @return [Boolean]
    def self.try_mysql_shared_lock(conn, base)
      mysql_lock_names(base).each do |name|
        next unless mysql_get_lock(conn, name)

        @mysql_held_locks = [name]
        return true
      end
      @mysql_held_locks = []
      false
    end

    # Release every pool name and keep the guard. The guard is never released
    # first, so this process always holds a lock the next copy needs.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @return [Boolean] false when this session does not hold the guard.
    def self.downgrade_mysql_lock_to_shared(conn, base)
      guard = mysql_guard_lock_name(base)
      held = Array(@mysql_held_locks)
      return false unless held.include?(guard)

      (held - [guard]).each { |name| mysql_release_lock(conn, name) }
      @mysql_held_locks = [guard]
      true
    end

    # Release the GET_LOCK names this session took for the current run.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @return [void]
    def self.release_held_mysql_locks(conn)
      Array(@mysql_held_locks).each { |name| mysql_release_lock(conn, name) }
      @mysql_held_locks = []
      nil
    end

    # One GET_LOCK name per worker daemon. The digest keeps each name inside 64
    # characters for any base database name.
    #
    # @param base [String]
    # @return [Array<String>]
    def self.mysql_lock_names(base)
      digest = mysql_lock_digest(base)
      (0...MYSQL_LOCK_SLOTS).map { |slot| "m:#{digest}:#{slot}" }
    end

    # Lock held for the whole copy and until worker daemons hold pool names.
    # Not part of {mysql_lock_names}, so it does not reduce the worker count.
    #
    # @param base [String]
    # @return [String]
    def self.mysql_guard_lock_name(base)
      "m:#{mysql_lock_digest(base)}:g"
    end

    # Shared prefix for the guard and the pool. 16 hex characters keep the full
    # lock name inside MySQL's 64-character limit.
    #
    # @param base [String]
    # @return [String]
    def self.mysql_lock_digest(base)
      Digest::SHA256.hexdigest("mutineer-run:#{base}")[0, 16]
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

    # Drop and create `name`. Refuses any name that is not one of `base`'s
    # worker database names, so a name bug can never drop the test database.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param name [String]
    # @param base [String] the test database name.
    # @return [void]
    def self.recreate_mysql_database(conn, name, base)
      raise "refusing to drop #{name}" unless owned_database?(base, name, slots: MYSQL_LOCK_SLOTS, limit: MYSQL_NAME_LIMIT)

      quoted = quote_mysql_ident(name)
      charset, collation = mysql_database_defaults(conn, base)
      mysql_exec(conn, "DROP DATABASE IF EXISTS #{quoted}")
      mysql_exec(conn, "CREATE DATABASE #{quoted} CHARACTER SET #{charset} COLLATE #{collation}")
    end

    # The test database's default character set and collation. A table the
    # schema creates without its own collation then compares text the same way
    # in each worker database as in the test database.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String] the test database name.
    # @return [Array(String, String)] the character set and the collation.
    # @raise [RuntimeError] when the test database is missing or reports an unexpected name.
    def self.mysql_database_defaults(conn, base)
      row = mysql_rows(conn, "SELECT DEFAULT_CHARACTER_SET_NAME AS charset, DEFAULT_COLLATION_NAME AS collation " \
                             "FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = #{mysql_quote_string(conn, base)}").first
      values = row && [row["charset"].to_s, row["collation"].to_s]
      raise "cannot read the character set of #{base}" unless values&.all? { |value| value.match?(/\A\w+\z/) }

      values
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

      switched = false
      failure = nil
      begin
        slot_hash = base_hash.merge(database: name)
        ActiveRecord::Base.establish_connection(slot_hash)
        switched = true
        db_config = mysql_db_config(slot_hash)
        format = current_schema_format
        file = mysql_schema_file(db_config, format)
        ActiveRecord::Tasks::DatabaseTasks.load_schema(db_config, format, file) if file
      rescue StandardError => e
        failure = e
      ensure
        if switched
          begin
            ActiveRecord::Base.establish_connection(base_hash)
          rescue StandardError => e
            failure ||= e
          end
        end
      end
      return unless failure
      raise failure if provision_wrapped?(failure)

      raise provision_failure(base, name, failure.message)
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
    # did not create is cloned with CREATE TABLE ... LIKE, then its foreign keys
    # are added. LIKE does not copy them. Each table's AUTO_INCREMENT is set
    # from the base after the rows, so a deleted high id is not reused.
    # Triggers the schema load created are dropped for the copy and created
    # again after it, so the copied rows match the base.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @param dest [String]
    # @return [void]
    def self.copy_mysql_rows(conn, base, dest)
      mysql_exec(conn, "SET FOREIGN_KEY_CHECKS = 0")
      # MySQL 8 caches information_schema.TABLES values, AUTO_INCREMENT among
      # them, for a day by default. The copy reads them live.
      begin
        mysql_exec(conn, "SET SESSION information_schema_stats_expiry = 0")
      rescue StandardError
        nil # MariaDB has no such cache or variable.
      end
      triggers = drop_mysql_triggers(conn, dest)
      tables = mysql_rows(conn, <<~SQL)
        SELECT TABLE_NAME AS table_name
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = #{mysql_quote_string(conn, base)}
          AND TABLE_TYPE = 'BASE TABLE'
      SQL
      names = []
      cloned = []
      tables.each do |row|
        table = row["table_name"].to_s
        next if table.empty?

        names << table
        cloned << table if ensure_mysql_table(conn, base, dest, table)
        columns = copyable_mysql_columns(conn, base, table)
        next if columns.empty?

        dest_table = "#{quote_mysql_ident(dest)}.#{quote_mysql_ident(table)}"
        base_table = "#{quote_mysql_ident(base)}.#{quote_mysql_ident(table)}"
        listed = columns.map { |column| quote_mysql_ident(column) }.join(", ")
        mysql_exec(conn, "DELETE FROM #{dest_table}")
        mysql_exec(conn, "INSERT INTO #{dest_table} (#{listed}) SELECT #{listed} FROM #{base_table}")
      end
      cloned.each { |table| copy_mysql_foreign_keys(conn, base, dest, table) }
      names.each { |table| copy_mysql_auto_increment(conn, base, dest, table) }
      restore_mysql_triggers(conn, dest, triggers)
    ensure
      begin
        mysql_exec(conn, "SET FOREIGN_KEY_CHECKS = 1")
      rescue StandardError
        nil
      end
    end

    # Drop every trigger on `dest` and return what {restore_mysql_triggers}
    # needs to create each one again. Triggers on one table event come back in
    # ACTION_ORDER. MySQL 8's CREATE text has no FOLLOWS or PRECEDES, so
    # creating them in that order keeps their order.
    #
    # The CREATE text is read as utf8mb4 with an empty sql_mode. mysql2 0.5.6
    # and older open utf8mb3, which turns a 4-byte character into "?". Under
    # ANSI_QUOTES, MySQL quotes the names with double quotes, which the
    # trigger's own sql_mode may not read. Backticks read in every sql_mode.
    # The session stays on utf8mb4, so {restore_mysql_triggers} sends the
    # text back unchanged.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param dest [String]
    # @return [Array<Hash>] `:name`, `:sql`, `:sql_mode` and `:collation` for each trigger.
    # @raise [RuntimeError] when SHOW CREATE TRIGGER returns no row for a trigger.
    def self.drop_mysql_triggers(conn, dest)
      rows = mysql_rows(conn, <<~SQL)
        SELECT TRIGGER_NAME AS trigger_name
        FROM information_schema.TRIGGERS
        WHERE TRIGGER_SCHEMA = #{mysql_quote_string(conn, dest)}
        ORDER BY EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION, ACTION_ORDER
      SQL
      return [] if rows.empty?

      sql_mode = mysql_rows(conn, "SELECT @@SESSION.sql_mode AS sql_mode").first["sql_mode"]
      mysql_exec(conn, "SET NAMES utf8mb4")
      mysql_exec(conn, "SET SESSION sql_mode = ''")
      # Limit: the text comes back as utf8mb4. In a trigger saved with another
      # client charset, a _binary or _latin1 literal that holds non-ASCII bytes
      # changes bytes on replay.
      triggers = rows.map do |row|
        name = row["trigger_name"].to_s
        shown = mysql_rows(conn, "SHOW CREATE TRIGGER #{quote_mysql_ident(dest)}.#{quote_mysql_ident(name)}").first
        raise "cannot read trigger #{name} on #{dest}" unless shown

        { name: name, sql: shown["sql original statement"].to_s, sql_mode: shown["sql_mode"].to_s,
          collation: shown["collation_connection"].to_s }
      end
      # Every definition is saved before the first drop.
      triggers.each { |trigger| mysql_exec(conn, "DROP TRIGGER #{quote_mysql_ident(dest)}.#{quote_mysql_ident(trigger[:name])}") }
      mysql_exec(conn, "SET SESSION sql_mode = #{mysql_quote_string(conn, sql_mode)}")
      triggers
    end

    # Create the triggers {drop_mysql_triggers} dropped. Each one is created
    # with its own sql_mode and connection collation, which decide how MySQL
    # reads its body. The CREATE text names no database, so this session
    # switches to `dest`. The sql_mode and collation go back to their values at
    # the start of this call. The character set stays utf8mb4. A failed create
    # names the trigger, for example when the DEFINER account needs SET_USER_ID.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param dest [String]
    # @param triggers [Array<Hash>]
    # @return [void]
    # @raise [RuntimeError] when MySQL refuses to create a trigger.
    def self.restore_mysql_triggers(conn, dest, triggers)
      return if triggers.empty?

      saved = mysql_rows(conn, "SELECT @@SESSION.sql_mode AS sql_mode, @@SESSION.collation_connection AS collation").first
      mysql_exec(conn, "USE #{quote_mysql_ident(dest)}")
      triggers.each do |trigger|
        mysql_exec(conn, mysql_session_modes_sql(conn, trigger[:sql_mode], trigger[:collation]))
        mysql_exec(conn, trigger[:sql])
      rescue StandardError => e
        raise "cannot recreate trigger #{trigger[:name]} on #{dest}: #{e.message}"
      end
      mysql_exec(conn, mysql_session_modes_sql(conn, saved["sql_mode"], saved["collation"]))
    end

    # SET statement for the session's sql_mode and connection collation.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param sql_mode [String]
    # @param collation [String]
    # @return [String]
    def self.mysql_session_modes_sql(conn, sql_mode, collation)
      "SET SESSION sql_mode = #{mysql_quote_string(conn, sql_mode)}, " \
        "collation_connection = #{mysql_quote_string(conn, collation)}"
    end

    # Create `table` on `dest` when the schema load did not. LIKE copies columns,
    # including generated columns, and does not copy foreign keys. The caller
    # adds those keys after every missing table exists.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @param dest [String]
    # @param table [String]
    # @return [Boolean] true when this call created the table.
    def self.ensure_mysql_table(conn, base, dest, table)
      rows = mysql_rows(conn, <<~SQL)
        SELECT TABLE_NAME AS table_name
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = #{mysql_quote_string(conn, dest)}
          AND TABLE_NAME = #{mysql_quote_string(conn, table)}
          AND TABLE_TYPE = 'BASE TABLE'
      SQL
      return false unless rows.empty?

      mysql_exec(conn, "CREATE TABLE #{quote_mysql_ident(dest)}.#{quote_mysql_ident(table)} LIKE #{quote_mysql_ident(base)}.#{quote_mysql_ident(table)}")
      true
    end

    # Add foreign keys from `base.table` onto `dest.table`. Keys that already
    # exist on `dest` are left alone. A referenced table in `base` is retargeted
    # at `dest` so the worker does not point back at the test database.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @param dest [String]
    # @param table [String]
    # @return [void]
    def self.copy_mysql_foreign_keys(conn, base, dest, table)
      existing = mysql_rows(conn, <<~SQL)
        SELECT CONSTRAINT_NAME AS constraint_name
        FROM information_schema.TABLE_CONSTRAINTS
        WHERE TABLE_SCHEMA = #{mysql_quote_string(conn, dest)}
          AND TABLE_NAME = #{mysql_quote_string(conn, table)}
          AND CONSTRAINT_TYPE = 'FOREIGN KEY'
      SQL
      have = existing.map { |row| row["constraint_name"].to_s }
      rows = mysql_rows(conn, <<~SQL)
        SELECT k.CONSTRAINT_NAME AS constraint_name,
               k.COLUMN_NAME AS column_name,
               k.ORDINAL_POSITION AS ordinal_position,
               k.REFERENCED_TABLE_SCHEMA AS referenced_table_schema,
               k.REFERENCED_TABLE_NAME AS referenced_table_name,
               k.REFERENCED_COLUMN_NAME AS referenced_column_name,
               r.UPDATE_RULE AS update_rule,
               r.DELETE_RULE AS delete_rule,
               r.MATCH_OPTION AS match_option
        FROM information_schema.KEY_COLUMN_USAGE k
        INNER JOIN information_schema.REFERENTIAL_CONSTRAINTS r
          ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
         AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
         AND r.TABLE_NAME = k.TABLE_NAME
        WHERE k.TABLE_SCHEMA = #{mysql_quote_string(conn, base)}
          AND k.TABLE_NAME = #{mysql_quote_string(conn, table)}
          AND k.REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
      SQL
      rows = rows.reject { |row| have.include?(row["constraint_name"].to_s) }
      sql = mysql_add_foreign_key_sql(dest, table, rows, base: base)
      mysql_exec(conn, sql) if sql
    end

    # One ALTER TABLE that adds every foreign key in `rows`.
    #
    # @param dest [String]
    # @param table [String]
    # @param rows [Array<Hash>]
    # @param base [String] test database name. References to it are rewritten to `dest`.
    # @return [String, nil]
    def self.mysql_add_foreign_key_sql(dest, table, rows, base:)
      clauses = mysql_foreign_key_clauses(rows, base: base, dest: dest)
      return nil if clauses.empty?

      "ALTER TABLE #{quote_mysql_ident(dest)}.#{quote_mysql_ident(table)} #{clauses.join(', ')}"
    end

    # ADD CONSTRAINT fragments for `rows`, grouped by constraint name.
    #
    # @param rows [Array<Hash>]
    # @param base [String]
    # @param dest [String]
    # @return [Array<String>]
    def self.mysql_foreign_key_clauses(rows, base:, dest:)
      grouped = {}
      Array(rows).each do |row|
        name = row["constraint_name"].to_s
        next if name.empty?

        (grouped[name] ||= []) << row
      end
      grouped.filter_map do |name, cols|
        ordered = cols.sort_by { |row| row["ordinal_position"].to_i }
        local_cols = ordered.map { |row| row["column_name"].to_s }
        ref_cols = ordered.map { |row| row["referenced_column_name"].to_s }
        ref_table = ordered.first["referenced_table_name"].to_s
        next if ref_table.empty? || local_cols.any?(&:empty?) || ref_cols.any?(&:empty?)

        ref_schema = ordered.first["referenced_table_schema"].to_s
        ref_schema = dest if ref_schema.empty? || ref_schema == base
        delete_rule = mysql_referential_action(ordered.first["delete_rule"])
        update_rule = mysql_referential_action(ordered.first["update_rule"])
        match = mysql_match_clause(ordered.first["match_option"])
        local_sql = local_cols.map { |column| quote_mysql_ident(column) }.join(", ")
        ref_sql = ref_cols.map { |column| quote_mysql_ident(column) }.join(", ")
        target = "#{quote_mysql_ident(ref_schema)}.#{quote_mysql_ident(ref_table)}"
        "ADD CONSTRAINT #{quote_mysql_ident(name)} FOREIGN KEY (#{local_sql}) REFERENCES #{target} (#{ref_sql})#{match} ON DELETE #{delete_rule} ON UPDATE #{update_rule}"
      end
    end

    # A foreign-key action safe to interpolate. Unknown text raises.
    #
    # @param value [String, nil]
    # @return [String]
    # @raise [ArgumentError] when `value` is not one of {MYSQL_REFERENTIAL_ACTIONS}.
    def self.mysql_referential_action(value)
      action = value.to_s.strip.upcase.tr("_", " ")
      return action if MYSQL_REFERENTIAL_ACTIONS.include?(action)

      raise ArgumentError, "unsupported foreign key action #{value.inspect}"
    end

    # MATCH fragment, or an empty string for the default NONE.
    #
    # @param value [String, nil]
    # @return [String]
    # @raise [ArgumentError] when `value` is not NONE, FULL, or PARTIAL.
    def self.mysql_match_clause(value)
      match = value.to_s.strip.upcase
      return "" if match.empty? || match == "NONE"
      return " MATCH #{match}" if %w[FULL PARTIAL].include?(match)

      raise ArgumentError, "unsupported foreign key match #{value.inspect}"
    end

    # Set `dest.table`'s AUTO_INCREMENT from the base table when the base has one.
    #
    # @param conn [Mysql2::Client, Trilogy]
    # @param base [String]
    # @param dest [String]
    # @param table [String]
    # @return [void]
    def self.copy_mysql_auto_increment(conn, base, dest, table)
      rows = mysql_rows(conn, <<~SQL)
        SELECT AUTO_INCREMENT AS auto_increment
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = #{mysql_quote_string(conn, base)}
          AND TABLE_NAME = #{mysql_quote_string(conn, table)}
      SQL
      sql = mysql_auto_increment_sql(dest, table, rows.dig(0, "auto_increment"))
      mysql_exec(conn, sql) if sql
    end

    # ALTER TABLE statement that sets AUTO_INCREMENT, or nil when `value` is blank.
    #
    # @param dest [String]
    # @param table [String]
    # @param value [Object]
    # @return [String, nil]
    def self.mysql_auto_increment_sql(dest, table, value)
      return nil if value.nil? || value.to_s.empty?

      number = Integer(value)
      return nil if number < 1

      "ALTER TABLE #{quote_mysql_ident(dest)}.#{quote_mysql_ident(table)} AUTO_INCREMENT = #{number}"
    rescue ArgumentError, TypeError
      nil
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
