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

  def config_for(jobs, model: "order", shared_databases: [])
    Mutineer::Config.new(
      sources: [File.join(APP, "app/models/#{model}.rb")],
      tests: [File.join(APP, "test/models/#{model}_test.rb")],
      project_root: APP, boot: "config/environment",
      rails: true, daemon: true, strategy: "reload", framework: "minitest", jobs: jobs,
      shared_databases: shared_databases
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

  # Each worker copies every SQLite database, so an app with two SQLite
  # databases runs parallel workers with no warning. Both workers get their
  # own copy of each file, and the score matches one worker. The deterministic
  # commit check is DaemonWorkerDbTest#test_each_worker_copies_the_second_database.
  def test_two_sqlite_databases_run_parallel_workers_and_match_one_worker
    ENV["MUTINEER_SECOND_DB"] = "1"
    slots = %w[test-1 extra-0 extra-1].map { |name| File.join(APP, "storage", "#{name}.sqlite3") }
    slots.each { |path| File.delete(path) if File.exist?(path) }
    serial = parallel = nil
    _out, err = capture_subprocess_io do
      serial,   = Mutineer::Runner.execute(config_for(1))
      parallel, = Mutineer::Runner.execute(config_for(2))
    end

    assert_equal 100.0, parallel.mutation_score
    assert_equal serial.killed_count, parallel.killed_count, "--jobs 2 == --jobs 1"
    assert_equal serial.survived_count, parallel.survived_count
    assert_equal 0, parallel.errored_count
    refute_match(/Mutineer runs one worker/, err)
    slots.each { |path| assert File.exist?(path), "#{File.basename(path)} must exist" }
  ensure
    ENV.delete("MUTINEER_SECOND_DB")
  end

  # #316: with the second database listed in shared_databases, the guard lifts.
  # No warning, a second worker starts, and the score matches one worker.
  def test_shared_databases_lets_a_second_database_run_parallel_workers
    ENV["MUTINEER_SECOND_DB"] = "1"
    slot1 = File.join(APP, "storage", "test-1.sqlite3")
    File.delete(slot1) if File.exist?(slot1)
    aggregate = nil
    _out, err = capture_subprocess_io do
      aggregate, = Mutineer::Runner.execute(config_for(4, shared_databases: %w[extra]))
    end

    assert_equal 100.0, aggregate.mutation_score
    assert_equal 0, aggregate.errored_count
    refute_match(/Mutineer runs one worker/, err)
    refute_match(/shared database used/, err)
    assert File.exist?(slot1), "a second worker must start"
  ensure
    ENV.delete("MUTINEER_SECOND_DB")
  end

  # #316: MUTINEER_EXTRA_POOL registers a pool for `extra`, so transactional
  # tests connect it in every test (the solid_cable case). A parallel run must
  # then score every mutant it runs `error`, never killed or survived.
  def test_a_used_shared_database_errors_every_parallel_mutant
    ENV["MUTINEER_SECOND_DB"] = "1"
    ENV["MUTINEER_EXTRA_POOL"] = "1"
    aggregate = nil
    _out, err = capture_subprocess_io do
      aggregate, = Mutineer::Runner.execute(config_for(2, shared_databases: %w[extra]))
    end

    assert_operator aggregate.errored_count, :>, 0
    assert_equal aggregate.total, aggregate.errored_count, "every mutant must score error"
    assert_equal 0, aggregate.killed_count
    assert_equal 0, aggregate.survived_count
    assert_includes err, "shared database used during a parallel run: extra."
  ensure
    ENV.delete("MUTINEER_SECOND_DB")
    ENV.delete("MUTINEER_EXTRA_POOL")
  end

  # #316: one worker shares nothing, so the same setup scores normally.
  def test_one_worker_runs_no_shared_database_check
    ENV["MUTINEER_SECOND_DB"] = "1"
    ENV["MUTINEER_EXTRA_POOL"] = "1"
    aggregate = nil
    _out, err = capture_subprocess_io do
      aggregate, = Mutineer::Runner.execute(config_for(1, shared_databases: %w[extra]))
    end

    assert_equal 100.0, aggregate.mutation_score
    assert_equal 0, aggregate.errored_count
    refute_match(/shared database used/, err)
  ensure
    ENV.delete("MUTINEER_SECOND_DB")
    ENV.delete("MUTINEER_EXTRA_POOL")
  end

  # #316: the daemon reports which database each worker copies, so listing it
  # stops the run before any mutant.
  def test_listing_the_primary_database_stops_the_run
    ENV["MUTINEER_SECOND_DB"] = "1"
    error = nil
    capture_subprocess_io do
      error = assert_raises(Mutineer::ConfigError) do
        Mutineer::Runner.execute(config_for(2, shared_databases: %w[primary extra]))
      end
    end

    assert_includes error.message, "shared_databases lists primary, the database each worker copies."
  ensure
    ENV.delete("MUTINEER_SECOND_DB")
  end

  # #253: the app loads lazily, so Zeitwerk first scans app/models/billing/ when
  # a mutant reopens Billing. Its own mutant file, and with two workers the other
  # worker's too, sit there by then. Their names are not constant names, so
  # before the fix the mutants of the file errored.
  def test_a_model_in_a_namespace_directory_is_scored_by_parallel_workers
    aggregate = nil
    capture_subprocess_io { aggregate, = Mutineer::Runner.execute(config_for(2, model: "billing/fee")) }

    assert_operator aggregate.killed_count, :>, 1
    assert_equal 100.0, aggregate.mutation_score
    assert_equal 0, aggregate.errored_count
  end
end
