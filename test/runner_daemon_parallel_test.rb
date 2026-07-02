# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/config"
require "mutineer/runner"

# #26/U6 — the R7 correctness gate (non-negotiable, KTD-9). N concurrent daemon
# workers, each pinned to its OWN isolated database, must produce verdicts IDENTICAL
# to serial: same score, same kill count, same survivor set — with no transactional-
# fixture cross-talk. Proven on SQLite here (Postgres is U10). This identity is what
# lets `--jobs N` become safe (and, later, default) under Rails.
class RunnerDaemonParallelTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)

  def config_for(test_file, jobs, fail_fast: false)
    Mutineer::Config.new(
      sources: [File.join(APP, "app/models/order.rb")],
      tests: [File.join(APP, "test/models/#{test_file}")],
      project_root: APP, boot: "config/environment",
      rails: true, daemon: true, strategy: "reload",
      framework: "minitest", jobs: jobs, fail_fast: fail_fast
    )
  end

  # Order-independent outcome identity: parallel finish order must not change it.
  def identity(aggregate)
    {
      score: aggregate.mutation_score,
      killed: aggregate.killed_count,
      survivors: aggregate.surviving_mutants.map(&:id).sort
    }
  end

  def assert_parallel_matches_serial(test_file)
    serial,   = Mutineer::Runner.execute(config_for(test_file, 1))
    parallel, = Mutineer::Runner.execute(config_for(test_file, 2))
    assert_equal identity(serial), identity(parallel),
                 "--jobs 2 must equal --jobs 1 (score/kills/survivors) on #{test_file}"
    [serial, parallel]
  end

  def test_strong_suite_jobs2_equals_jobs1_and_scores_100
    serial, parallel = assert_parallel_matches_serial("order_test.rb")
    assert_equal 100.0, parallel.mutation_score
    assert_empty parallel.surviving_mutants, "strong suite leaves no survivors under --jobs 2"
    assert_operator serial.killed_count, :>, 0
  end

  def test_weak_suite_jobs2_equals_jobs1_with_real_survivors
    serial, parallel = assert_parallel_matches_serial("order_weak_test.rb")
    refute_empty parallel.surviving_mutants, "weak suite should still leave survivors under --jobs 2"
    assert_operator parallel.mutation_score, :<, 100.0
    assert_operator serial.killed_count, :>, 0
  end

  # The identity above only holds because --fail-fast forces the serial path even
  # under --jobs 2 (a wall-clock stop in the parallel path would make the survivor
  # set/score non-deterministic). Proves the guard, not just its absence of crashing.
  def test_fail_fast_jobs2_equals_fail_fast_jobs1
    serial,   = Mutineer::Runner.execute(config_for("order_weak_test.rb", 1, fail_fast: true))
    parallel, = Mutineer::Runner.execute(config_for("order_weak_test.rb", 2, fail_fast: true))
    assert_equal identity(serial), identity(parallel),
                 "--fail-fast --jobs 2 must equal --fail-fast --jobs 1 (guarded to serial)"
  end
end
