# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "mutineer/rails_worker_db"

# #26/U5 — zero-dep unit coverage for the pure parts of the worker-DB adapter. The
# path-munging is the one bit of non-trivial logic that could break silently, so it
# gets a fast check here; the AR-backed routing is proven end-to-end in
# test/daemon_worker_db_test.rb (daemon suite, under the fixture app bundle).
class RailsWorkerDbTest < Minitest::Test
  def test_worker_database_path_inserts_worker_before_extension
    assert_equal "storage/test-0.sqlite3",
                 Mutineer::RailsWorkerDb.worker_database_path("storage/test.sqlite3", 0)
    assert_equal "storage/test-3.sqlite3",
                 Mutineer::RailsWorkerDb.worker_database_path("storage/test.sqlite3", 3)
  end

  def test_worker_database_path_handles_a_bare_name
    assert_equal "mydb-1", Mutineer::RailsWorkerDb.worker_database_path("mydb", 1)
  end

  # R10: the adapter must never touch AR unless the app loaded it. In the zero-dep
  # suite AR is absent, so `available?` must be a strict `false` (not nil) — the guard
  # every other method relies on.
  def test_available_reflects_active_record_presence
    expected = defined?(ActiveRecord::Base) ? true : false
    assert_equal expected, Mutineer::RailsWorkerDb.available?
  end

  # U10 seam: per_worker_config is adapter-general and pure (no AR), so the Postgres
  # worker-DB naming is proven ready here — the remaining U10 work is PG provisioning
  # (CREATE DATABASE), not the config shape.
  def test_per_worker_config_derives_sqlite_worker_database
    cfg = Mutineer::RailsWorkerDb.per_worker_config({ adapter: "sqlite3", database: "storage/test.sqlite3" }, 1)
    assert_equal "storage/test-1.sqlite3", cfg[:database]
    assert_equal "sqlite3", cfg[:adapter]
  end

  def test_per_worker_config_derives_postgres_worker_database
    cfg = Mutineer::RailsWorkerDb.per_worker_config({ "adapter" => "postgresql", "database" => "myapp_test" }, 2)
    assert_equal "myapp_test-mutineer-2", cfg[:database]
    assert_equal "postgresql", cfg[:adapter]
    assert_equal "myapp_test-mutineer-3",
                 Mutineer::RailsWorkerDb.postgres_worker_database("myapp_test", 3)
  end

  def test_long_multibyte_postgres_names_stop_on_a_character
    base = "é" * 30
    name = Mutineer::RailsWorkerDb.postgres_worker_database(base, 1)
    assert_operator name.bytesize, :<=, Mutineer::RailsWorkerDb::POSTGRES_NAME_LIMIT
    assert_equal Encoding::UTF_8, name.encoding
    assert_predicate name, :valid_encoding?
    assert_match(/\A(?:é)+-[0-9a-f]{8}-mutineer-1\z/, name)
    assert Mutineer::RailsWorkerDb.worker_database_name?(base, name)

    emoji = "😀" * 20
    wide = Mutineer::RailsWorkerDb.postgres_worker_database(emoji, 4)
    assert_operator wide.bytesize, :<=, Mutineer::RailsWorkerDb::POSTGRES_NAME_LIMIT
    assert_predicate wide, :valid_encoding?
    assert_match(/\A(?:😀)+-[0-9a-f]{8}-mutineer-4\z/, wide)
  end

  def test_long_postgres_names_stay_within_63_bytes_and_differ_by_slot
    base = "a" * 60
    one = Mutineer::RailsWorkerDb.postgres_worker_database(base, 1)
    two = Mutineer::RailsWorkerDb.postgres_worker_database(base, 2)
    assert_operator one.bytesize, :<=, 63
    assert_operator two.bytesize, :<=, 63
    refute_equal one, two

    shared = "b" * 50
    left = Mutineer::RailsWorkerDb.postgres_worker_database("#{shared}#{'c' * 10}", 1)
    right = Mutineer::RailsWorkerDb.postgres_worker_database("#{shared}#{'d' * 10}", 1)
    refute_equal left, right
    assert_operator left.bytesize, :<=, 63
    assert_operator right.bytesize, :<=, 63
  end

  def test_owned_database_matches_the_exact_worker_name_only
    assert Mutineer::RailsWorkerDb.owned_database?("myapp_test", "myapp_test-mutineer-1", slots: 4)
    # "_" is not a wildcard here. A SQL LIKE against myXappXtest would lie.
    refute Mutineer::RailsWorkerDb.owned_database?("myXappXtest", "my_app_test-mutineer-1", slots: 4)
  end

  def test_mysql2_and_trilogy_use_mysql_worker_names
    %w[mysql2 trilogy].each do |adapter|
      cfg = Mutineer::RailsWorkerDb.per_worker_config({ adapter: adapter, database: "app_test" }, 4)
      assert_equal "app_test-mutineer-4", cfg[:database]
      assert_equal adapter, cfg[:adapter]
      assert_equal "app_test-mutineer-4", Mutineer::RailsWorkerDb.mysql_worker_database("app_test", 4)
    end
  end

  def test_long_mysql_names_stay_within_64_bytes_and_differ_by_slot
    base = "a" * 70
    one = Mutineer::RailsWorkerDb.mysql_worker_database(base, 1)
    two = Mutineer::RailsWorkerDb.mysql_worker_database(base, 2)
    assert_operator one.bytesize, :<=, 64
    assert_operator two.bytesize, :<=, 64
    refute_equal one, two

    shared = "b" * 60
    left = Mutineer::RailsWorkerDb.mysql_worker_database("#{shared}#{'c' * 20}", 1)
    right = Mutineer::RailsWorkerDb.mysql_worker_database("#{shared}#{'d' * 20}", 1)
    refute_equal left, right
    assert Mutineer::RailsWorkerDb.owned_database?(base, one, slots: 2, limit: Mutineer::RailsWorkerDb::MYSQL_NAME_LIMIT)
    refute Mutineer::RailsWorkerDb.owned_database?(base, one, slots: 2)
  end

  def test_mysql_lock_names_stay_within_64_characters
    names = Mutineer::RailsWorkerDb.mysql_lock_names("x" * 200)
    assert_equal Mutineer::RailsWorkerDb::MYSQL_LOCK_SLOTS, names.size
    names.each { |name| assert_operator name.length, :<=, 64 }
    refute_equal names.first, names.last
  end

  def test_recreate_refuses_a_name_outside_the_worker_pattern
    conn = Object.new
    conn.define_singleton_method(:exec) { |*| flunk "must not touch a database outside the worker pattern" }
    conn.define_singleton_method(:escape_literal) { |*| flunk "must not touch a database outside the worker pattern" }
    ["analytics", "myapp_test", "postgres", "template0", "other_app-mutineer-0"].each do |name|
      error = assert_raises(RuntimeError) do
        Mutineer::RailsWorkerDb.recreate_from_template(conn, name, "myapp_test")
      end
      assert_match(/\Arefusing to drop #{Regexp.escape(name)}\z/, error.message)
    end
  end

  def test_mysql_recreate_refuses_a_name_outside_the_worker_pattern
    conn = Object.new
    conn.define_singleton_method(:query) { |*| flunk "must not touch a database outside the worker pattern" }
    ["analytics", "myapp_test", "mysql", "other_app-mutineer-0"].each do |name|
      error = assert_raises(RuntimeError) do
        Mutineer::RailsWorkerDb.recreate_mysql_database(conn, name, "myapp_test")
      end
      assert_match(/\Arefusing to drop #{Regexp.escape(name)}\z/, error.message)
    end
  end

  def test_recreate_drops_only_the_canonical_worker_name
    calls = []
    conn = Object.new
    conn.define_singleton_method(:escape_literal) { |value| "'#{value}'" }
    conn.define_singleton_method(:exec) { |sql| calls << sql }
    name = Mutineer::RailsWorkerDb.postgres_worker_database("myapp_test", 0)

    Mutineer::RailsWorkerDb.recreate_from_template(conn, name, "myapp_test")

    assert_equal 3, calls.size
    assert_includes calls[1], "DROP DATABASE IF EXISTS \"myapp_test-mutineer-0\""
    refute_includes calls.join("\n"), "DROP DATABASE IF EXISTS \"myapp_test\""
    refute_includes calls.join("\n"), "DROP DATABASE IF EXISTS \"postgres\""
  end

  def test_maintenance_options_keep_service_and_target_postgres
    opts = Mutineer::RailsWorkerDb.maintenance_connection_options(
      "adapter" => "postgresql",
      "service" => "ci_pg",
      "database" => "myapp_test",
      "username" => "app",
      "password" => "secret",
      "schema_search_path" => "public",
      "variables" => { "statement_timeout" => "5s" }
    )
    assert_equal "postgres", opts[:dbname]
    assert_equal "ci_pg", opts[:service]
    assert_equal "app", opts[:user]
    assert_equal "secret", opts[:password]
    refute opts.key?(:database)
    refute opts.key?(:schema_search_path)
    refute opts.key?(:variables)
    refute opts.key?(:adapter)
  end

  def test_maintenance_options_read_a_database_url
    opts = Mutineer::RailsWorkerDb.maintenance_connection_options(
      url: "postgres://app:p%40ss+word@db.internal:5433/myapp_test?sslmode=require",
      host: "override.internal",
      service: "ci_pg"
    )
    assert_equal "postgres", opts[:dbname]
    assert_equal "override.internal", opts[:host]
    assert_equal 5433, opts[:port]
    assert_equal "app", opts[:user]
    assert_equal "p@ss+word", opts[:password]
    assert_equal "require", opts[:sslmode]
    assert_equal "ci_pg", opts[:service]
    refute_includes opts.values, "myapp_test"
  end

  def test_a_malformed_database_url_does_not_print_its_password
    error = assert_raises(RuntimeError) do
      Mutineer::RailsWorkerDb.options_from_database_url("postgres://u:s3cret@ho st/db")
    end
    # Callers re-raise a "could not provision" error unchanged, so the prefix stays.
    assert_match(/\Acould not provision: the database URL is not valid/, error.message)
    # full_message also prints the cause chain, where the parser's error repeats the URL.
    refute_includes error.full_message, "s3cret"
  end

  def test_per_worker_config_reads_the_database_from_a_url
    cfg = Mutineer::RailsWorkerDb.per_worker_config(
      { adapter: "postgresql", url: "postgres://db.internal/myapp_test" }, 1
    )
    assert_equal "myapp_test-mutineer-1", cfg[:database]
    assert_equal "postgresql", cfg[:adapter]
  end

  def test_a_service_without_a_database_name_is_an_explicit_error
    config = { adapter: "postgresql", service: "ci_pg" }
    error = assert_raises(RuntimeError) do
      Mutineer::RailsWorkerDb.source_database_name!(config)
    end
    assert_match(/test database name is missing/, error.message)

    Mutineer::RailsWorkerDb.stub(:current_config_hash, config) do
      raised = assert_raises(RuntimeError) { Mutineer::RailsWorkerDb.provision_postgres(1) }
      assert_match(/test database name is missing/, raised.message)
      refute_match(/pg client/, raised.message)
    end
  end

  def test_provision_uses_the_url_host_without_a_live_server
    seen = {}
    config = { adapter: "postgresql", url: "postgres://app:secret@db.internal:5433/myapp_test" }
    opener = lambda do |hash, base|
      seen[:base] = base
      seen[:opts] = Mutineer::RailsWorkerDb.maintenance_connection_options(hash)
      raise "stop before the server"
    end
    Mutineer::RailsWorkerDb.stub(:current_config_hash, config) do
      Mutineer::RailsWorkerDb.stub(:open_maintenance_connection, opener) do
        error = assert_raises(RuntimeError) { Mutineer::RailsWorkerDb.provision_postgres(1) }
        assert_equal "stop before the server", error.message
      end
    end
    assert_equal "myapp_test", seen[:base]
    assert_equal "db.internal", seen[:opts][:host]
    assert_equal 5433, seen[:opts][:port]
    assert_equal "postgres", seen[:opts][:dbname]
    assert_equal "app", seen[:opts][:user]
  end

  def test_open_maintenance_connection_forwards_service_to_the_client
    connection = Class.new do
      class << self
        attr_accessor :opened

        def open(opts)
          self.opened = opts
          :conn
        end
      end
    end
    pg = Module.new
    pg.const_set(:Connection, connection)
    Object.const_set(:PG, pg)
    result = Mutineer::RailsWorkerDb.open_maintenance_connection(
      { service: "ci_pg", database: "myapp_test", username: "app" },
      "myapp_test"
    )
    assert_equal :conn, result
    assert_equal "postgres", connection.opened[:dbname]
    assert_equal "ci_pg", connection.opened[:service]
    assert_equal "app", connection.opened[:user]
  ensure
    Object.send(:remove_const, :PG) if Object.const_defined?(:PG)
  end

  def test_old_mysql_adapter_is_not_provisioned_here
    error = assert_raises(NotImplementedError) do
      Mutineer::RailsWorkerDb.per_worker_config({ adapter: "mysql", database: "app_test" }, 0)
    end
    refute_includes error.message, "Postgres per-worker provisioning is not yet supported"
  end

  def test_per_worker_config_rejects_memory_database
    assert_raises(NotImplementedError) do
      Mutineer::RailsWorkerDb.per_worker_config({ adapter: "sqlite3", database: ":memory:" }, 0)
    end
  end

  # #222: a seeded worker reloads schema.rb only when its version differs.
  def test_schema_file_version_reads_the_declared_version
    assert_equal 20_240_102_030_405,
                 Mutineer::RailsWorkerDb.schema_file_version("ActiveRecord::Schema[7.1].define(version: 2024_01_02_030405) do")
    assert_equal 1, Mutineer::RailsWorkerDb.schema_file_version("ActiveRecord::Schema.define(version: 1) do")
    assert_nil Mutineer::RailsWorkerDb.schema_file_version("ActiveRecord::Schema.define do")
  end

  def teardown
    db = Mutineer::RailsWorkerDb
    db.forget_mysql_base_config
    db.instance_variable_set(:@mysql_held_locks, nil)
    db.instance_variable_set(:@lock_connection, nil)
  end

  # A server that requires TLS refuses a maintenance session without it.
  def test_mysql_client_options_keep_tls_and_timeout_keys
    opts = Mutineer::RailsWorkerDb.mysql_client_options(
      adapter: "mysql2", host: "db", database: "app_test", pool: 5, variables: { sql_mode: "" },
      ssl_mode: "verify_identity", sslca: "/ca.pem", sslcert: "/c.pem", sslkey: "/k.pem", connect_timeout: 5
    )
    assert_equal "verify_identity", opts[:ssl_mode]
    assert_equal ["/ca.pem", "/c.pem", "/k.pem"], opts.values_at(:sslca, :sslcert, :sslkey)
    assert_equal 5, opts[:connect_timeout]
    refute opts.key?(:database)
    refute opts.key?(:pool)
    refute opts.key?(:variables)

    trilogy = Mutineer::RailsWorkerDb.mysql_client_options(ssl: true, ssl_ca: "/ca.pem", tls_min_version: 3)
    assert_equal [true, "/ca.pem", 3], trilogy.values_at(:ssl, :ssl_ca, :tls_min_version)
  end

  def test_mysql_client_options_use_a_custom_socket_instead_of_host
    opts = Mutineer::RailsWorkerDb.mysql_client_options(
      adapter: "trilogy", host: "127.0.0.1", port: 3306, socket: "/run/app/mysql.sock",
      username: "app", password: "secret", database: "app_test"
    )
    assert_equal "/run/app/mysql.sock", opts[:socket]
    assert_nil opts[:host]
    assert_nil opts[:port]
    refute opts.key?(:database)
    assert_equal "app", opts[:username]
    assert_equal "secret", opts[:password]

    host_only = Mutineer::RailsWorkerDb.mysql_client_options(host: "db.internal", port: "3306")
    assert_equal "db.internal", host_only[:host]
    assert_equal 3306, host_only[:port]
    refute host_only.key?(:socket)
  end

  def test_trilogy_client_gets_the_socket_and_no_database
    fake = Class.new do
      attr_reader :options

      def initialize(options)
        @options = options
      end
    end
    had = Object.const_defined?(:Trilogy)
    previous = Object.const_get(:Trilogy) if had
    Object.send(:remove_const, :Trilogy) if had
    Object.const_set(:Trilogy, fake)

    conn = Mutineer::RailsWorkerDb.open_mysql_connection(
      { adapter: "trilogy", socket: "/tmp/mysql.sock", username: "app", database: "app_test" },
      "app_test"
    )
    assert_equal "/tmp/mysql.sock", conn.options[:socket]
    refute conn.options.key?(:database)
    refute conn.options.key?(:host)
  ensure
    Object.send(:remove_const, :Trilogy) if Object.const_defined?(:Trilogy)
    Object.const_set(:Trilogy, previous) if had
  end

  def test_remembered_mysql_base_is_not_nested_for_a_later_fork
    slot = Mutineer::RailsWorkerDb.per_worker_config({ adapter: "trilogy", database: "app_test" }, 0)
    assert_equal "app_test-mutineer-0-mutineer-0",
                 Mutineer::RailsWorkerDb.per_worker_config(slot, 0)[:database]

    Mutineer::RailsWorkerDb.remember_mysql_base_config(
      adapter: "trilogy", database: "app_test", socket: "/tmp/mysql.sock"
    )
    cfg = Mutineer::RailsWorkerDb.worker_db_config(0)
    assert_equal "app_test-mutineer-0", cfg[:database]
    assert_equal "/tmp/mysql.sock", cfg[:socket]
    assert_equal "trilogy", cfg[:adapter]
  end

  def test_provision_mysql_remembers_the_base_before_the_client_opens
    base = { adapter: "trilogy", database: "app_test", socket: "/tmp/mysql.sock" }
    db = Mutineer::RailsWorkerDb
    db.stub(:routing_config_hash, base) do
      db.stub(:open_mysql_connection, ->(*) { raise "stop after remember" }) do
        error = assert_raises(RuntimeError) { db.provision_mysql(1) }
        assert_equal "stop after remember", error.message
      end
    end
    cfg = db.worker_db_config(0)
    assert_equal "app_test-mutineer-0", cfg[:database]
    assert_equal "/tmp/mysql.sock", cfg[:socket]
  end

  def test_load_mysql_schema_restores_the_base_connection
    saved = Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    calls = []
    base = Class.new do
      define_singleton_method(:establish_connection) { |config| calls << config[:database] }
      define_singleton_method(:schema_format) { :ruby }
    end
    tasks = Module.new do
      define_singleton_method(:schema_dump_path) { |_config, _format| "/missing/schema.rb" }
    end
    hash_config = Class.new do
      def initialize(*)
      end
    end
    active_record = Module.new
    active_record.const_set(:Base, base)
    active_record.const_set(:Tasks, Module.new)
    active_record::Tasks.const_set(:DatabaseTasks, tasks)
    active_record.const_set(:DatabaseConfigurations, Module.new)
    active_record::DatabaseConfigurations.const_set(:HashConfig, hash_config)
    Object.const_set(:ActiveRecord, active_record)

    Mutineer::RailsWorkerDb.load_mysql_schema(
      { adapter: "trilogy", database: "app_test" }, "app_test-mutineer-0", "app_test"
    )
    assert_equal %w[app_test-mutineer-0 app_test], calls
  ensure
    Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    Object.const_set(:ActiveRecord, saved) if saved
  end

  # The tool counts these names; the primary is the config each worker copies.
  # Hidden configs count, replicas do not.
  def test_database_names_lists_the_test_configs_and_the_primary
    saved = Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    config = Struct.new(:name, :replica) do
      def replica? = replica
    end
    # `legacy` stands for a `database_tasks: false` config: Rails hides it
    # unless include_hidden is set, and workers would still share it.
    all = [config.new("primary"), config.new("primary_replica", true), config.new("cable"), config.new("legacy")]
    configs = Object.new
    configs.define_singleton_method(:configs_for) do |env_name:, include_hidden: false|
      include_hidden ? all : all.first(1) + all[2, 1]
    end
    base = Class.new
    base.define_singleton_method(:configurations) { configs }
    base.define_singleton_method(:connection_db_config) { config.new("primary") }
    Object.const_set(:ActiveRecord, Module.new.tap { |m| m.const_set(:Base, base) })

    Mutineer::RailsWorkerDb.stub(:current_adapter, "postgresql") do
      assert_equal({ "names" => %w[primary cable legacy], "primary" => "primary", "copied" => %w[primary] },
                   Mutineer::RailsWorkerDb.database_names)
    end
  ensure
    Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    Object.const_set(:ActiveRecord, saved) if saved
  end

  # On SQLite each worker copies every file database. An in-memory one is not
  # copied, so it still counts toward the one-worker limit.
  def test_database_names_on_sqlite_copies_every_file_database
    saved = Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    config = Struct.new(:name, :adapter, :database, :replica) do
      def replica? = replica
    end
    all = [config.new("primary", "sqlite3", "storage/test.sqlite3"),
           config.new("primary_replica", "sqlite3", "storage/test.sqlite3", true),
           config.new("cable", "sqlite3", "storage/cable.sqlite3"),
           config.new("scratch", "sqlite3", ":memory:")]
    configs = Object.new
    configs.define_singleton_method(:configs_for) { |env_name:, include_hidden: false| all }
    base = Class.new
    base.define_singleton_method(:configurations) { configs }
    base.define_singleton_method(:connection_db_config) { all.first }
    Object.const_set(:ActiveRecord, Module.new.tap { |m| m.const_set(:Base, base) })

    Mutineer::RailsWorkerDb.stub(:current_adapter, "sqlite3") do
      assert_equal({ "names" => %w[primary cable scratch], "primary" => "primary", "copied" => %w[primary cable] },
                   Mutineer::RailsWorkerDb.database_names)
    end
  ensure
    Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    Object.const_set(:ActiveRecord, saved) if saved
  end

  # A SQLite DatabaseConfig stand-in: `_database=` rewrites it, as Rails' does.
  SqliteConfig = Struct.new(:name, :database, :adapter) do
    def _database=(value)
      self.database = value
    end
  end

  # Every SQLite file config moves to the worker's file. A replica on the
  # primary's file shares its copy. A shared config, and an in-memory or
  # non-SQLite one, keep their database.
  def test_route_sqlite_configs_rewrites_each_file_config_but_shared_ones
    db = Mutineer::RailsWorkerDb
    configs = [SqliteConfig.new("primary", "/app/test.sqlite3", "sqlite3"),
               SqliteConfig.new("primary_replica", "/app/test.sqlite3", "sqlite3"),
               SqliteConfig.new("cable", "/app/cable.sqlite3", "sqlite3"),
               SqliteConfig.new("queue", "/app/queue.sqlite3", "sqlite3"),
               SqliteConfig.new("scratch", ":memory:", "sqlite3"),
               SqliteConfig.new("legacy", "legacy_test", "postgresql")]
    routed = kept = nil
    db.stub(:test_configs, configs) { routed, kept = db.route_sqlite_configs(3, seed: false, shared: %w[queue]) }

    assert_equal %w[/app/test-3.sqlite3 /app/test-3.sqlite3 /app/cable-3.sqlite3 /app/queue.sqlite3 :memory: legacy_test],
                 configs.map(&:database)
    assert_equal %w[/app/test-3.sqlite3 /app/cable-3.sqlite3], routed
    assert_equal %w[/app/queue.sqlite3], kept
  end

  # A primary Mutineer cannot copy (in memory, a `file:` URI) fails the fork
  # with `error` rather than running every worker on one shared database.
  def test_after_fork_refuses_a_sqlite_primary_it_cannot_copy
    saved = Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    db = Mutineer::RailsWorkerDb
    [":memory:", "file:test.sqlite3?mode=rwc", ""].each do |database|
      primary = SqliteConfig.new("primary", database, "sqlite3")
      base = Class.new
      base.define_singleton_method(:connection_db_config) { primary }
      Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
      Object.const_set(:ActiveRecord, Module.new.tap { |m| m.const_set(:Base, base) })
      db.stub(:current_adapter, "sqlite3") do
        error = assert_raises(NotImplementedError) { db.after_fork(0) }
        assert_includes error.message, "needs a SQLite database file (got #{database.inspect})"
      end
    end
  ensure
    Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    Object.const_set(:ActiveRecord, saved) if saved
  end

  # The routing check: a pool on a SQLite file that is neither a worker file
  # nor a shared base (an inline establish_connection hash) raises. Routed
  # pools get a round-trip; shared pools do not, so the shared check stays clean.
  def test_verify_routing_raises_for_an_unrouted_pool_and_skips_shared_ones
    saved = Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    pool = Struct.new(:db_config, :trips) do
      def with_connection
        self.trips += 1
        yield Object.new.tap { |c| c.define_singleton_method(:execute) { |_sql| nil } }
      end
    end
    routed = pool.new(SqliteConfig.new("primary", "/app/test-0.sqlite3", "sqlite3"), 0)
    shared = pool.new(SqliteConfig.new("queue", "/app/queue.sqlite3", "sqlite3"), 0)
    inline = pool.new(SqliteConfig.new("primary", "/tmp/inline.sqlite3", "sqlite3"), 0)
    pools = [routed, shared]
    handler = Object.new
    handler.define_singleton_method(:connection_pool_list) { |_role| pools }
    base = Class.new
    base.define_singleton_method(:connection_handler) { handler }
    Object.const_set(:ActiveRecord, Module.new.tap { |m| m.const_set(:Base, base) })
    db = Mutineer::RailsWorkerDb

    db.verify_routing!(%w[/app/test-0.sqlite3], %w[/app/queue.sqlite3])
    assert_equal [1, 0], [routed.trips, shared.trips]

    pools << inline
    error = assert_raises(RuntimeError) { db.verify_routing!(%w[/app/test-0.sqlite3], %w[/app/queue.sqlite3]) }
    assert_includes error.message, "primary still uses /tmp/inline.sqlite3, which every worker shares."
  ensure
    Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    Object.const_set(:ActiveRecord, saved) if saved
  end

  # The tripwire reads the live pools: a connected pool on a shared database
  # is a use, under its own name or as a replica of it. An idle pool is not.
  def test_touched_shared_databases_names_connected_shared_pools_only
    saved = Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    config = Struct.new(:name, :database)
    pool = Struct.new(:db_config, :connected) do
      def connected? = connected
    end
    cable = config.new("cable", "storage/cable.sqlite3")
    queue = config.new("queue", "storage/queue.sqlite3")
    replica = config.new("queue_replica", "storage/queue.sqlite3")
    primary = config.new("primary", "storage/test.sqlite3")
    pools = [pool.new(primary, true), pool.new(cable, true), pool.new(queue, false), pool.new(cable, true)]
    handler = Object.new
    handler.define_singleton_method(:connection_pool_list) { |role| role == :all ? pools : [] }
    configs = Object.new
    configs.define_singleton_method(:configs_for) { |env_name:, include_hidden:| [primary, cable, queue, replica] }
    base = Class.new
    base.define_singleton_method(:connection_handler) { handler }
    base.define_singleton_method(:configurations) { configs }
    version = Gem::Version.new("7.2.3")
    active_record = Module.new.tap { |m| m.const_set(:Base, base) }
    active_record.define_singleton_method(:version) { version }
    Object.const_set(:ActiveRecord, active_record)

    db = Mutineer::RailsWorkerDb
    assert_equal %w[cable], db.touched_shared_databases(%w[cable queue])
    assert_empty db.touched_shared_databases(%w[queue])
    assert_empty db.touched_shared_databases([])

    pools << pool.new(replica, true)
    assert_equal %w[queue], db.touched_shared_databases(%w[queue]), "a replica read is a use of the shared database"

    # Rails 7.0 lists no pool for :all, so a pass there would be a false clean.
    version = Gem::Version.new("7.0.8")
    error = assert_raises(RuntimeError) { db.touched_shared_databases(%w[cable]) }
    assert_equal "shared_databases needs Rails 7.1 or later", error.message
  ensure
    Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
    Object.const_set(:ActiveRecord, saved) if saved
  end

  def test_too_many_mysql_workers_fail_before_a_connection
    error = assert_raises(RuntimeError) do
      Mutineer::RailsWorkerDb.provision_mysql(Mutineer::RailsWorkerDb::MYSQL_LOCK_SLOTS + 1)
    end
    assert_match(/at most #{Mutineer::RailsWorkerDb::MYSQL_LOCK_SLOTS} workers/, error.message)
    assert_operator Mutineer::RailsWorkerDb::MYSQL_LOCK_SLOTS, :>, 64
  end

  def test_mysql_lock_downgrade_never_drops_every_lock
    box = LockBox.new
    first = LockMysql.new(box, :first)
    second = LockMysql.new(box, :second)
    base = "app_test"
    guard = Mutineer::RailsWorkerDb.mysql_guard_lock_name(base)

    assert Mutineer::RailsWorkerDb.try_mysql_lock(first, base, shared: false)
    assert Mutineer::RailsWorkerDb.downgrade_mysql_lock_to_shared(first, base)
    refute box.went_empty?, "the guard lock was released before another lock was held"
    assert_equal [guard], box.held_by(:first)
    assert Mutineer::RailsWorkerDb.try_mysql_lock(second, base, shared: true)
    assert_equal [guard], box.held_by(:first)
    refute Mutineer::RailsWorkerDb.try_mysql_lock(LockMysql.new(box, :third), base, shared: false)

    box.release(:first, guard)
    refute Mutineer::RailsWorkerDb.try_mysql_lock(LockMysql.new(box, :fourth), base, shared: false)
    box.held_by(:second).each { |name| box.release(:second, name) }
    assert Mutineer::RailsWorkerDb.try_mysql_lock(LockMysql.new(box, :fifth), base, shared: false)
  end

  def test_a_fork_child_forgets_mysql_lock_names_without_releasing_them
    conn = Object.new
    Mutineer::RailsWorkerDb.instance_variable_set(:@lock_connection, conn)
    Mutineer::RailsWorkerDb.instance_variable_set(:@mysql_held_locks, ["m:abc:g"])
    Mutineer::RailsWorkerDb.forget_lock_connection_after_fork!
    assert_nil Mutineer::RailsWorkerDb.instance_variable_get(:@lock_connection)
    assert_empty Mutineer::RailsWorkerDb.instance_variable_get(:@mysql_held_locks)
  end

  # Mutant forks reach the lock only through after_fork, so the hook itself
  # must forget the parent's lock connection before it connects the worker.
  def test_after_fork_forgets_the_lock_connection_before_connecting
    db = Mutineer::RailsWorkerDb
    db.instance_variable_set(:@lock_connection, Object.new)
    db.instance_variable_set(:@mysql_held_locks, ["m:abc:g"])
    seen = :not_called
    db.stub(:available?, true) do
      db.stub(:current_adapter, "mysql2") do
        db.stub(:connect, ->(_slot) { seen = db.instance_variable_get(:@lock_connection) }) do
          db.stub(:verify_connection!, nil) { db.after_fork(0) }
        end
      end
    end
    assert_nil seen
    assert_empty db.instance_variable_get(:@mysql_held_locks)
  end

  def test_mysql_recreate_copies_the_test_database_collation
    queries = []
    conn = Object.new
    conn.define_singleton_method(:escape) { |value| value }
    conn.define_singleton_method(:query) do |sql|
      queries << sql
      HashRows.new([{ "charset" => "utf8mb4", "collation" => "utf8mb4_0900_ai_ci" }]) if sql.include?("SCHEMATA")
    end
    Mutineer::RailsWorkerDb.recreate_mysql_database(conn, "myapp_test-mutineer-0", "myapp_test")
    assert_equal "CREATE DATABASE `myapp_test-mutineer-0` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci", queries.last
  end

  # A freed client sends QUIT (mysql2) or Terminate (pg) on the shared socket,
  # which ends the parent's lock session. Each client is detached first.
  def test_a_fork_child_detaches_each_client_before_forgetting_it
    mysql2 = Struct.new(:automatic_close).new(true)
    trilogy = Class.new { attr_reader :discarded; def discard! = (@discarded = true) }.new
    socket = Class.new { attr_reader :target; def reopen(io) = (@target = io) }.new
    pg = Struct.new(:socket_io).new(socket)

    [mysql2, trilogy, pg].each do |conn|
      Mutineer::RailsWorkerDb.instance_variable_set(:@lock_connection, conn)
      Mutineer::RailsWorkerDb.forget_lock_connection_after_fork!
    end

    assert_equal false, mysql2.automatic_close
    assert trilogy.discarded
    assert_equal IO::NULL, socket.target
  end

  def test_trilogy_row_copy_keeps_foreign_keys_and_auto_increment
    conn = ScriptedMysql.new(
      tables: [{ "table_name" => "children" }],
      columns: [
        { "column_name" => "id", "extra" => "auto_increment" },
        { "column_name" => "parent_id", "extra" => "" },
        { "column_name" => "other_id", "extra" => "" },
        { "column_name" => "total", "extra" => "STORED GENERATED" }
      ],
      existing_keys: [{ "constraint_name" => "fk_children_external" }],
      foreign_keys: [
        {
          "constraint_name" => "fk_children_parent",
          "column_name" => "other_id",
          "ordinal_position" => "2",
          "referenced_table_schema" => "app_test",
          "referenced_table_name" => "parents",
          "referenced_column_name" => "other_id",
          "update_rule" => "RESTRICT",
          "delete_rule" => "CASCADE",
          "match_option" => "NONE"
        },
        {
          "constraint_name" => "fk_children_parent",
          "column_name" => "parent_id",
          "ordinal_position" => "1",
          "referenced_table_schema" => "app_test",
          "referenced_table_name" => "parents",
          "referenced_column_name" => "id",
          "update_rule" => "RESTRICT",
          "delete_rule" => "CASCADE",
          "match_option" => "NONE"
        },
        {
          "constraint_name" => "fk_children_external",
          "column_name" => "other_id",
          "ordinal_position" => "1",
          "referenced_table_schema" => "shared_db",
          "referenced_table_name" => "codes",
          "referenced_column_name" => "id",
          "update_rule" => "NO ACTION",
          "delete_rule" => "SET NULL",
          "match_option" => "FULL"
        }
      ],
      auto_increment: "40"
    )
    Mutineer::RailsWorkerDb.copy_mysql_rows(conn, "app_test", "app_test-mutineer-0")
    sql = conn.queries.join("\n")
    refute_match(/DROP DATABASE/i, sql)
    # No triggers: no session changes and no trigger statements.
    refute_match(/SET NAMES|SHOW CREATE TRIGGER|^USE /, sql)
    assert_includes sql, "CREATE TABLE `app_test-mutineer-0`.`children` LIKE `app_test`.`children`"
    assert_includes sql, "INSERT INTO `app_test-mutineer-0`.`children` (`id`, `parent_id`, `other_id`)"
    refute_includes sql, "`total`"
    assert_includes sql,
                    "ADD CONSTRAINT `fk_children_parent` FOREIGN KEY (`parent_id`, `other_id`) " \
                    "REFERENCES `app_test-mutineer-0`.`parents` (`id`, `other_id`) " \
                    "ON DELETE CASCADE ON UPDATE RESTRICT"
    refute_includes sql, "fk_children_external"
    assert_includes sql, "ALTER TABLE `app_test-mutineer-0`.`children` AUTO_INCREMENT = 40"
    assert_nil Mutineer::RailsWorkerDb.mysql_auto_increment_sql("app_test-mutineer-0", "children", nil)
  end

  def test_row_copy_drops_triggers_first_and_creates_them_again_last
    conn = trigger_conn
    Mutineer::RailsWorkerDb.copy_mysql_rows(conn, "app_test", "app_test-mutineer-0")
    sql = conn.queries
    at = ->(text) { sql.index { |query| query.start_with?(text) } || flunk("no #{text} in #{sql.inspect}") }
    listing = sql.find { |query| query.include?("information_schema.TRIGGERS") }
    assert_includes listing, "TRIGGER_SCHEMA = 'app_test-mutineer-0'"
    assert_includes listing, "ORDER BY EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION, ACTION_ORDER"
    assert_operator at.("SET NAMES utf8mb4"), :<, at.("SHOW CREATE TRIGGER")
    assert_operator at.("SET SESSION sql_mode = ''"), :<, at.("SHOW CREATE TRIGGER")
    assert_equal ["DROP TRIGGER `app_test-mutineer-0`.`items_audit`", "DROP TRIGGER `app_test-mutineer-0`.`items_label`"],
                 sql.grep(/\ADROP TRIGGER/)
    assert_operator sql.rindex { |query| query.start_with?("SHOW CREATE TRIGGER") }, :<, at.("DROP TRIGGER")
    assert_operator sql.rindex { |query| query.start_with?("DROP TRIGGER") }, :<, at.("SET SESSION sql_mode = 'STRICT")
    assert_operator at.("SET SESSION sql_mode = 'STRICT"), :<, at.("INSERT INTO")
    assert_operator at.("ALTER TABLE"), :<, at.("USE `app_test-mutineer-0`")
    replay = sql.drop(at.("USE `app_test-mutineer-0`") + 1).first(5)
    assert_equal [
      "SET SESSION sql_mode = 'NO_ENGINE_SUBSTITUTION', collation_connection = 'utf8mb4_unicode_ci'",
      "CREATE TRIGGER `items_audit`",
      "SET SESSION sql_mode = 'ANSI_QUOTES', collation_connection = 'utf8mb4_unicode_ci'",
      "CREATE TRIGGER `items_label`",
      "SET SESSION sql_mode = 'STRICT_TRANS_TABLES', collation_connection = 'utf8mb4_0900_ai_ci'"
    ], replay
  end

  def test_a_refused_trigger_create_names_the_trigger
    conn = trigger_conn
    def conn.query(sql)
      raise "Access denied; you need the SET_USER_ID privilege" if sql.start_with?("CREATE TRIGGER")

      super
    end
    error = assert_raises(RuntimeError) do
      Mutineer::RailsWorkerDb.copy_mysql_rows(conn, "app_test", "app_test-mutineer-0")
    end
    assert_equal "cannot recreate trigger items_audit on app_test-mutineer-0: " \
                 "Access denied; you need the SET_USER_ID privilege", error.message
  end

  def test_an_unreadable_trigger_stops_the_copy_before_any_drop
    conn = trigger_conn
    def conn.rows_for(sql)
      return [] if sql.start_with?("SHOW CREATE TRIGGER") && sql.include?("`items_label`")

      super
    end
    error = assert_raises(RuntimeError) do
      Mutineer::RailsWorkerDb.copy_mysql_rows(conn, "app_test", "app_test-mutineer-0")
    end
    assert_equal "cannot read trigger items_label on app_test-mutineer-0", error.message
    assert_empty conn.queries.grep(/\ADROP TRIGGER|\AINSERT INTO/)
  end

  # One copied table with two schema triggers, each saved in its own sql_mode.
  def trigger_conn
    ScriptedMysql.new(
      tables: [{ "table_name" => "items" }], columns: [{ "column_name" => "id", "extra" => "" }],
      foreign_keys: [], auto_increment: "3", existing_tables: [{ "table_name" => "items" }],
      triggers: { "items_audit" => "NO_ENGINE_SUBSTITUTION", "items_label" => "ANSI_QUOTES" }
    )
  end

  def test_an_unknown_foreign_key_action_is_rejected
    rows = [{
      "constraint_name" => "fk_bad",
      "column_name" => "parent_id",
      "ordinal_position" => "1",
      "referenced_table_schema" => "app_test",
      "referenced_table_name" => "parents",
      "referenced_column_name" => "id",
      "update_rule" => "RESTRICT",
      "delete_rule" => "DROP TABLE",
      "match_option" => "NONE"
    }]
    assert_raises(ArgumentError) do
      Mutineer::RailsWorkerDb.mysql_add_foreign_key_sql("slot", "children", rows, base: "app_test")
    end
  end

  # Rows from a client that only implements trilogy's each_hash.
  class HashRows
    def initialize(rows)
      @rows = rows
    end

    def each_hash
      @rows.each { |row| yield row }
    end
  end

  # Records SQL and answers the information_schema reads the row copy makes.
  class ScriptedMysql
    attr_reader :queries

    def initialize(tables:, columns:, foreign_keys:, auto_increment:, existing_tables: [], existing_keys: [], triggers: {})
      @queries = []
      @tables = tables
      @columns = columns
      @foreign_keys = foreign_keys
      @auto_increment = auto_increment
      @existing_tables = existing_tables
      @existing_keys = existing_keys
      @triggers = triggers
    end

    def query(sql)
      @queries << sql
      HashRows.new(rows_for(sql))
    end

    def escape(value)
      value.to_s.gsub("\\") { "\\\\" }.gsub("'", "''")
    end

    def rows_for(sql)
      if sql.include?("information_schema.TRIGGERS")
        @triggers.keys.map { |name| { "trigger_name" => name } }
      elsif (name = sql[/\ASHOW CREATE TRIGGER `[^`]+`\.`([^`]+)`/, 1])
        [{ "sql original statement" => "CREATE TRIGGER `#{name}`", "sql_mode" => @triggers[name],
           "collation_connection" => "utf8mb4_unicode_ci" }]
      elsif sql.include?("@@SESSION")
        [{ "sql_mode" => "STRICT_TRANS_TABLES", "collation" => "utf8mb4_0900_ai_ci" }]
      elsif sql.include?("REFERENCED_TABLE_NAME")
        @foreign_keys
      elsif sql.include?("CONSTRAINT_TYPE")
        @existing_keys
      elsif sql.include?("AUTO_INCREMENT")
        [{ "auto_increment" => @auto_increment }]
      elsif sql.include?("COLUMN_NAME")
        @columns
      elsif sql.include?("TABLE_NAME =")
        @existing_tables
      elsif sql.include?("TABLE_TYPE")
        @tables
      else
        []
      end
    end
  end

  # In-memory GET_LOCK / RELEASE_LOCK so two sessions can race without MySQL.
  class LockBox
    def initialize
      @owner = {}
      @went_empty = false
    end

    def get(owner, name)
      return false if @owner.key?(name) && @owner[name] != owner

      @owner[name] = owner
      true
    end

    def release(owner, name)
      @owner.delete(name) if @owner[name] == owner
      @went_empty = true if @owner.none? { |_held, who| who == owner }
    end

    def held_by(owner)
      @owner.select { |_name, who| who == owner }.keys
    end

    def went_empty?
      @went_empty
    end
  end

  # One session against a {LockBox}. Result rows use trilogy's each_hash.
  class LockMysql
    def initialize(box, id)
      @box = box
      @id = id
    end

    def query(sql)
      if sql.include?("GET_LOCK")
        name = sql[/GET_LOCK\('([^']*)'/, 1]
        got = @box.get(@id, name)
        HashRows.new([{ "got" => got ? "1" : "0" }])
      elsif sql.include?("RELEASE_LOCK")
        name = sql[/RELEASE_LOCK\('([^']*)'/, 1]
        @box.release(@id, name)
        HashRows.new([])
      else
        HashRows.new([])
      end
    end

    def escape(value)
      value.to_s.gsub("'", "''")
    end
  end
end
