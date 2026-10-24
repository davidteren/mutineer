# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_server"

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
      used
    end
  end

  def setup
    FakeWorkerDb.asked = nil
    FakeWorkerDb.used = []
  end

  def teardown
    %i[@worker_db @shared_databases].each { |ivar| daemon.instance_variable_set(ivar, nil) }
  end

  def test_databases_reports_the_adapter_answer_or_nil_without_one
    daemon.instance_variable_set(:@worker_db, FakeWorkerDb)
    assert_equal({ "names" => %w[primary cable], "primary" => "primary" }, daemon.send(:databases))

    daemon.instance_variable_set(:@worker_db, nil)
    assert_nil daemon.send(:databases)
  end

  def test_a_used_shared_database_raises_so_the_mutant_scores_error
    daemon.instance_variable_set(:@worker_db, FakeWorkerDb)
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
