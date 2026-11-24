# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/config"
require "mutineer/runner"
require "mutineer/reporter"
require "json"

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
    refute_match(/databases; Mutineer runs one worker/, err)
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

  # The fixture app loads lazily. Shipment's class body declares an enum and
  # skips its parent's callback, and its concern has an `included` block.
  # Reload runs that body a second time, which raised before #378, #383, and
  # #384. The daemon must now score every mutant. bin/dogfood checks the
  # in-process reload path, which needs the fixture's own bundle.
  def reloaded_class_body_config
    Mutineer::Config.new(
      sources: %w[app/models/shipment.rb app/models/concerns/trackable.rb].map { |f| File.join(APP, f) },
      tests: %w[test/models/shipment_test.rb test/models/concerns/trackable_test.rb].map { |f| File.join(APP, f) },
      project_root: APP, boot: "config/environment",
      rails: true, daemon: true, strategy: "reload", framework: "minitest", jobs: 2
    )
  end

  def test_a_class_body_with_enum_skip_callback_and_lazy_concern_reloads_on_the_daemon
    aggregate = nil
    _out, err = capture_subprocess_io { aggregate, = Mutineer::Runner.execute(reloaded_class_body_config) }

    assert_equal 0, aggregate.errored_count, err
    # cubic: each source must score on its own, so losing the concern's
    # mutants cannot hide behind the model's.
    by_source = aggregate.by_source.to_h { |file, agg| [File.basename(file), agg] }
    assert_equal %w[shipment.rb trackable.rb], by_source.keys.sort
    by_source.each do |file, agg|
      assert_operator agg.killed_count, :>, 0, file
      assert_equal 0, agg.errored_count, file
      assert_equal 100.0, agg.mutation_score, file
    end
    assert_equal 100.0, aggregate.mutation_score
  end

  # The check above passes even if every mutant is a false kill. With a weak
  # test that checks only the enum, the skips and the concern's scope, every
  # mutant must run and survive: a broken class body would error or kill.
  def test_a_reloaded_class_body_keeps_its_enum_skips_and_scope_on_the_daemon
    config = reloaded_class_body_config
    config.tests = [File.join(APP, "test/models/shipment_weak_test.rb")]
    aggregate = nil
    _out, err = capture_subprocess_io { aggregate, = Mutineer::Runner.execute(config) }

    assert_equal 0, aggregate.errored_count, err
    assert_operator aggregate.survived_count, :>, 1
    assert_equal aggregate.total, aggregate.survived_count, "every mutant must run and survive"
  end

  # #492: InclusionValue < Data.define(...). Each load of that line builds a new
  # superclass, so the daemon raised "superclass mismatch" for every mutant. The
  # test checks both answers of switch?, so each mutant must run and be killed.
  def test_the_daemon_reloads_a_class_with_a_call_superclass
    aggregate = nil
    _out, err = capture_subprocess_io do
      aggregate, = Mutineer::Runner.execute(config_for(1, model: "inclusion_value"))
    end

    assert_equal 0, aggregate.errored_count, err
    assert_operator aggregate.killed_count, :>, 0
    assert_equal 100.0, aggregate.mutation_score
  end

  # #503 and #512: LedgerRow inherits from a constant its file assigns, and
  # LedgerRow::Line's superclass sets a local a later line reads. Each load
  # built a new class, so the daemon raised "superclass mismatch" for every
  # mutant. The test checks both answers of each predicate and the local, so
  # each mutant must run and be killed.
  def test_the_daemon_reloads_a_superclass_constant_and_a_superclass_local
    aggregate = nil
    _out, err = capture_subprocess_io do
      aggregate, = Mutineer::Runner.execute(config_for(1, model: "ledger_row"))
    end

    assert_equal 0, aggregate.errored_count, err
    statuses = aggregate.results.group_by { |r| r.subject.qualified_name }.transform_values { |rs| rs.map(&:status).uniq }
    # Each shape reaches its test: every mutant of each subject is killed.
    assert_equal({ "LedgerRow#zero?" => [:killed], "LedgerRow::Line#single?" => [:killed] }, statuses)
  end

  # #504: OwnChainNote's body calls `define_callbacks :save`, and its concern
  # adds `before_save :stamp`. The daemon ran that call again for each mutant,
  # which cleared the chain, so the test of the callback log failed and every
  # `urgent?` mutant was a false kill. No test checks `urgent?`, so each of
  # its mutants must survive. `only` keeps out the mutants of `stamp`, `log`
  # and `save`, which the log test kills for a true reason.
  def test_the_daemon_keeps_a_chain_the_class_body_defines
    config = config_for(1, model: "own_chain_note")
    config.only = "OwnChainNote#urgent?"
    aggregate = extras = nil
    _out, err = capture_subprocess_io { aggregate, _map, extras = Mutineer::Runner.execute(config) }

    assert_equal 0, aggregate.errored_count, err
    assert_operator aggregate.total, :>, 0
    assert_equal aggregate.total, aggregate.survived_count, "every urgent? mutant must run and survive"
    assert_empty extras[:callback_growth]
  end

  # #543: QuietNote's body skips its concern's `stamp` callback with
  # `if: :quiet?`. The daemon ran that skip again for each mutant, which added
  # the condition a second time, so `quiet?` ran twice on each save, the test
  # of the log failed, and every `urgent?` mutant was a false kill. No test
  # checks `urgent?`, so each of its mutants must survive.
  def test_the_daemon_does_not_repeat_a_conditional_skip
    config = config_for(1, model: "quiet_note")
    config.only = "QuietNote#urgent?"
    aggregate = nil
    _out, err = capture_subprocess_io { aggregate, = Mutineer::Runner.execute(config) }

    assert_equal 0, aggregate.errored_count, err
    assert_operator aggregate.total, :>, 0
    assert_equal aggregate.total, aggregate.survived_count, "every urgent? mutant must run and survive"
  end

  # #504: HelperChainNote's body defines its chain through `note_callbacks`.
  # The reload guard skips a chain the class already has, so a mutant in the
  # helper (such as `true` to `false` for `skip_after_callbacks_if_terminated`)
  # never reached Rails and scored `survived` unapplied. Discovery now marks
  # the helper, so each of its mutants is `unplaceable` and counted apart.
  def test_the_daemon_marks_a_helper_that_defines_a_chain_unplaceable
    config = config_for(1, model: "helper_chain_note")
    config.only = "HelperChainNote.note_callbacks"
    aggregate = source_map = nil
    _out, err = capture_subprocess_io { aggregate, source_map, = Mutineer::Runner.execute(config) }

    assert_equal 0, aggregate.errored_count, err
    assert_operator aggregate.total, :>, 0
    assert_equal [:unplaceable], aggregate.results.map(&:status).uniq
    assert(aggregate.results.all? { |r| r.subject.calls_define_callbacks }, "the cause is the #504 mark")
    out = StringIO.new
    Mutineer::Reporter.new(aggregate, source_map).report(out: out, err: StringIO.new, format: "json")
    doc = JSON.parse(out.string)
    assert_equal aggregate.total, doc["summary"]["unplaceable"]
    assert_equal aggregate.total, doc["unplaceable"].size
    assert_equal 0, doc["summary"]["survived"]
  end

  # #479: StampedNote's concern and class body add the same `&:stamp`
  # callback, so reload keeps both copies. With two workers, the run names the
  # class once, with its file, and the verdicts do not change: the test checks
  # both answers of `urgent?`, so its mutants are killed.
  def test_the_daemon_reports_a_class_whose_callback_count_grew_once
    aggregate = extras = nil
    _out, err = capture_subprocess_io do
      aggregate, _map, extras = Mutineer::Runner.execute(config_for(2, model: "stamped_note"))
    end

    assert_equal 0, aggregate.errored_count, err
    assert_equal [%w[StampedNote app/models/stamped_note.rb]], extras[:callback_growth]
    assert_operator aggregate.killed_count, :>, 0
  end

  # #390: the daemon reloads Parcel's whole file, so its class body runs again
  # and appended a second validator, block callback and `validate` block.
  # ParcelTest counts them, so every `heavy?` mutant was a false kill. The
  # test never checks `heavy?`, so each mutant must survive, as it does under
  # in-process redefine (bin/dogfood compares the two).
  def test_the_daemon_runs_each_validator_and_block_callback_once
    aggregate = nil
    capture_subprocess_io { aggregate, = Mutineer::Runner.execute(config_for(1, model: "parcel")) }

    assert_operator aggregate.survived_count, :>, 0
    assert_equal aggregate.total, aggregate.survived_count, "every mutant must run and survive"
  end

  # #414: eager load, as production does, loads the subclasses before a
  # mutant reloads the parent. Rails then appends the parent's callback to a
  # subclass that skipped it. The weak `heavy?` mutants must still survive.
  def test_a_parent_reload_does_not_restore_a_skipped_subclass_callback
    ENV["MUTINEER_EAGER_LOAD"] = "1"
    aggregate = nil
    _out, err = capture_subprocess_io do
      aggregate, = Mutineer::Runner.execute(config_for(1, model: "postage"))
    end

    assert_equal 0, aggregate.errored_count, err
    assert_operator aggregate.killed_count, :>, 0, "require_weight must still be killed"
    assert_operator aggregate.survived_count, :>, 0, "heavy? must survive; a restored callback kills it"
  ensure
    ENV.delete("MUTINEER_EAGER_LOAD")
  end

  # #385: with Rails' pending-migration check on (a new app's default),
  # rails/test_help queries every database when the tests load, shared ones
  # too. Mutant forks turn the check off, so the shared database stays unused.
  def test_the_pending_migration_check_does_not_trip_the_shared_database_check
    ENV["MUTINEER_SECOND_DB"] = "1"
    ENV["MUTINEER_MAINTAIN_SCHEMA"] = "1"
    aggregate = nil
    _out, err = capture_subprocess_io do
      aggregate, = Mutineer::Runner.execute(config_for(2, shared_databases: %w[extra]))
    end

    refute_match(/shared database used/, err)
    assert_equal 0, aggregate.errored_count
    assert_equal 100.0, aggregate.mutation_score
  ensure
    ENV.delete("MUTINEER_SECOND_DB")
    ENV.delete("MUTINEER_MAINTAIN_SCHEMA")
  end
end
