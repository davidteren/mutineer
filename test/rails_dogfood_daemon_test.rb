# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/config"
require "mutineer/runner"

# #26/U9 — end-to-end dogfood of the daemon backend on the bundled Rails fixture app
# (SQLite). The holistic proof that ties the phase together: a parallel run's verdicts
# equal a serial run's AND the run emits ZERO database-contention warnings — the exact
# corruption signal (#12/#26: PG deadlocks / "could not disable referential integrity")
# that made --jobs unsafe under Rails before per-worker DB isolation. Postgres is U10;
# error/killed/timeout distinctness is covered by the daemon core tests.
class RailsDogfoodDaemonTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)

  def config_for(jobs)
    Mutineer::Config.new(
      sources: [File.join(APP, "app/models/order.rb")],
      tests: [File.join(APP, "test/models/order_test.rb")],
      project_root: APP, boot: "config/environment",
      rails: true, daemon: true, strategy: "reload", framework: "minitest", jobs: jobs
    )
  end

  def test_parallel_dogfood_matches_serial_with_no_db_warnings
    rails_parallel_databases.each { |path| File.delete(path) }
    serial = parallel = nil
    # Daemons are subprocesses; capture at the fd level so their drained stderr
    # (where any AR deadlock / referential-integrity warning would surface) is seen.
    out, err = capture_subprocess_io do
      serial,   = Mutineer::Runner.execute(config_for(1))
      parallel, = Mutineer::Runner.execute(config_for(2))
    end

    assert_equal 100.0, parallel.mutation_score, "strong suite scores 100 under --jobs 2"
    assert_equal serial.mutation_score, parallel.mutation_score, "--jobs 2 == --jobs 1"
    assert_equal serial.killed_count, parallel.killed_count

    combined = out + err
    refute_match(/deadlock/i, combined, "no DB deadlock warnings under --jobs 2")
    refute_match(/referential integrity/i, combined, "no referential-integrity warnings")
    refute_match(/database is locked/i, combined, "no SQLite lock contention under --jobs 2")
    created = rails_parallel_databases
    assert_empty created, "Rails parallelize must not create #{created.inspect}"
  end

  # Rails suffixes the database with -<n> or _<n>. SQLite's own -wal and -shm
  # files share the first pattern and are not worker databases.
  def rails_parallel_databases
    Dir.glob(File.join(APP, "storage", "test.sqlite3-*"))
      .concat(Dir.glob(File.join(APP, "storage", "test.sqlite3_*")))
      .select { |path| File.basename(path).match?(/\Atest\.sqlite3[-_]\d+\z/) }
  end

  # More than one database config is only known after boot. The run warns once
  # and uses one worker, so only slot 0's file appears.
  def test_several_databases_run_one_worker_and_warn_once
    ENV["MUTINEER_SECOND_DB"] = "1"
    slot1 = File.join(APP, "storage", "test-1.sqlite3")
    File.delete(slot1) if File.exist?(slot1)
    aggregate = nil
    _out, err = capture_subprocess_io do
      aggregate, = Mutineer::Runner.execute(config_for(4))
    end

    assert_equal 100.0, aggregate.mutation_score
    sentence = "this app has 2 databases; Mutineer runs one worker. Parallel runs support one database."
    assert_equal 1, err.scan(sentence).size
    refute File.exist?(slot1), "a second worker must not start"
    assert File.exist?(File.join(APP, "storage", "test-0.sqlite3"))
  ensure
    ENV.delete("MUTINEER_SECOND_DB")
  end
end
