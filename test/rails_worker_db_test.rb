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

    def initialize(tables:, columns:, foreign_keys:, auto_increment:, existing_tables: [], existing_keys: [])
      @queries = []
      @tables = tables
      @columns = columns
      @foreign_keys = foreign_keys
      @auto_increment = auto_increment
      @existing_tables = existing_tables
      @existing_keys = existing_keys
    end

    def query(sql)
      @queries << sql
      HashRows.new(rows_for(sql))
    end

    def escape(value)
      value.to_s.gsub("\\", "\\\\").gsub("'", "''")
    end

    def rows_for(sql)
      if sql.include?("REFERENCED_TABLE_NAME")
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
