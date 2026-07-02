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
end
