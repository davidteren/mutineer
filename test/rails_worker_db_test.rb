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
end
