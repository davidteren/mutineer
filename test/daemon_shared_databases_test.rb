# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_server"
require "tempfile"

# The daemon side of `shared_databases`: the database report the tool counts,
# and the check that fails a parallel worker's mutant when a test used a shared
# database. Rails-free: a stand-in plays RailsWorkerDb.
class DaemonSharedDatabasesTest < Minitest::Test
  # A stand-in for RailsWorkerDb that records the names the check asks about.
  class FakeWorkerDb
    class << self
      # @return [Array<String>] names the last tripwire check was given.
      attr_accessor :asked
      # @return [Array<String>] names the tripwire reports as used.
      attr_accessor :used
    end

    # @return [Hash]
    def self.database_names = { "names" => %w[primary cable], "primary" => "primary" }

    # @return [Array<String>]
    def self.touched_shared_databases(shared)
      self.asked = shared
      # In a fork, only a pool recorded since watch_sql counts as used.
      @watching ? used : []
    end

    # @return [String]
    def self.primary_database_name = "primary"

    # @return [void]
    def self.watch_sql
      @watching = true
    end

    # @return [void]
    def self.after_fork(*, **); end
  end

  # A lookup that fails. The primary alone may still resolve, or not.
  class FailedLookupDb
    class << self
      # @return [String, nil] the primary name, or nil when it fails too.
      attr_accessor :primary
    end

    # @raise [RuntimeError]
    def self.database_names = raise("no pool")

    # @return [String]
    def self.primary_database_name = primary || raise("no config")
  end

  def setup
    FakeWorkerDb.asked = nil
    FakeWorkerDb.instance_variable_set(:@watching, false)
    FakeWorkerDb.used = []
  end

  def teardown
    %i[@worker_db @shared_databases @errio @slot_ready @source_dirs].each { |ivar| daemon.instance_variable_set(ivar, nil) }
  end

  def test_databases_reports_the_adapter_answer_or_nil_without_one
    daemon.instance_variable_set(:@worker_db, FakeWorkerDb)
    assert_equal({ "names" => %w[primary cable], "primary" => "primary" }, daemon.send(:databases))

    daemon.instance_variable_set(:@worker_db, nil)
    assert_nil daemon.send(:databases)
  end

  # The tool still rejects a listed primary when the full lookup fails, so
  # the failed report keeps the primary name when it resolves.
  def test_a_failed_lookup_reports_the_primary_when_it_resolves
    daemon.instance_variable_set(:@worker_db, FailedLookupDb)
    FailedLookupDb.primary = "primary"
    assert_equal({ "error" => "RuntimeError: no pool", "primary" => "primary" }, daemon.send(:databases))

    FailedLookupDb.primary = nil
    assert_equal({ "error" => "RuntimeError: no pool", "primary" => nil }, daemon.send(:databases))
  end

  # The fork starts the SQL watch before its tests, so the check sees a pool
  # a test closed. The fake reports a use only after watch_sql ran in that
  # fork. A serial daemon (no names) never watches, so its mutant scores normally.
  def test_a_parallel_fork_watches_sql_before_the_check
    Tempfile.create("daemon_err") do |errio|
      errio.sync = true
      daemon.instance_variable_set(:@errio, errio)
      daemon.instance_variable_set(:@worker_db, FakeWorkerDb)
      daemon.instance_variable_set(:@slot_ready, {})
      daemon.instance_variable_set(:@source_dirs, [])
      FakeWorkerDb.used = %w[cable]
      verdicts = daemon.stub(:apply_payload, nil) do
        daemon.stub(:run_tests, 0) do
          [%w[cable], []].map do |names|
            daemon.instance_variable_set(:@shared_databases, names)
            daemon.send(:run_mutant, "id" => 1, "worker" => 0, "timeout" => 10)["verdict"]
          end
        end
      end

      assert_equal %w[error survived], verdicts
      assert_includes File.read(errio.path), "shared database used during a parallel run: cable."
    end
  end

  def test_a_used_shared_database_raises_so_the_mutant_scores_error
    daemon.instance_variable_set(:@worker_db, FakeWorkerDb)
    FakeWorkerDb.watch_sql
    daemon.instance_variable_set(:@shared_databases, %w[cable queue])
    FakeWorkerDb.used = %w[cable]

    error = assert_raises(RuntimeError) { daemon.send(:check_shared_databases!) }
    assert_includes error.message, "shared database used during a parallel run: cable."
    assert_equal %w[cable queue], FakeWorkerDb.asked
  end

  def test_an_unused_shared_database_passes
    daemon.instance_variable_set(:@worker_db, FakeWorkerDb)
    daemon.instance_variable_set(:@shared_databases, %w[cable])

    assert_nil daemon.send(:check_shared_databases!)
    assert_equal %w[cable], FakeWorkerDb.asked
  end

  # A serial worker daemon gets no names, so it never asks.
  def test_no_names_means_no_check
    daemon.instance_variable_set(:@worker_db, FakeWorkerDb)
    daemon.instance_variable_set(:@shared_databases, [])
    FakeWorkerDb.used = %w[cable]

    assert_nil daemon.send(:check_shared_databases!)
    assert_nil FakeWorkerDb.asked
  end

  private

  # @return [Module]
  def daemon = Mutineer::DaemonServer
end
