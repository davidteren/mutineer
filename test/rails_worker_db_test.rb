# frozen_string_literal: true

require_relative "test_helper"
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

  def test_mysql_adapter_is_not_provisioned_here
    error = assert_raises(NotImplementedError) do
      Mutineer::RailsWorkerDb.per_worker_config({ adapter: "mysql2", database: "app_test" }, 0)
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
end
