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
  end
end
