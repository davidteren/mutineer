# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "mutineer/config"
require "mutineer/runner"
require "mutineer/cli"

# #26/#27 Phase 2a (U4): Runner.execute_daemon drives the persistent daemon serially
# against the bundled fixture app and produces the SAME verdicts the in-process
# `--rails` path is designed to produce — the R1 correctness identity, strategy held
# constant (reload both sides). Tool-side runs in this process (Prism); only the
# daemon subprocess boots Rails.
class RunnerDaemonTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)

  def config_for(test_file)
    Mutineer::Config.new(
      sources: [File.join(APP, "app/models/order.rb")],
      tests: [File.join(APP, "test/models/#{test_file}")],
      project_root: APP,
      boot: "config/environment",
      rails: true,
      daemon: true,
      strategy: "reload",
      framework: "minitest"
    )
  end

  # The strong suite is built to kill every mutant on a covered line -> 100%, no
  # survivors. Proves daemon verdicts match the known-correct answers.
  def test_strong_suite_scores_100_via_daemon
    aggregate, = Mutineer::Runner.execute(config_for("order_test.rb"))
    assert_operator aggregate.killed_count, :>, 0, "strong suite should kill mutants"
    assert_empty aggregate.surviving_mutants, "strong suite leaves no survivors"
    assert_equal 100.0, aggregate.mutation_score
  end

  # The weak suite executes every method but asserts almost nothing, so arithmetic
  # mutants on the add/subtract boundary survive -> sub-100%, real survivors.
  def test_weak_suite_reports_survivors_via_daemon
    aggregate, = Mutineer::Runner.execute(config_for("order_weak_test.rb"))
    refute_empty aggregate.surviving_mutants, "weak suite should leave survivors"
    assert_operator aggregate.mutation_score, :<, 100.0
    assert_operator aggregate.killed_count, :>, 0, "weak suite still kills some"
  end

  # Successful daemon coverage narrowing: no stale "lower bound / no narrowing"
  # caveat. Fallback-only warnings live on Runner.daemon_coverage_map (nil map).
  def test_cli_does_not_claim_stale_daemon_lower_bound_when_map_ok
    _out, err = capture_io do
      assert_raises(SystemExit) { Mutineer::CLI.execute(config_for("order_test.rb")) }
    end
    refute_match(/--daemon score is a lower bound/, err)
    refute_match(/no coverage narrowing yet/, err)
    refute_match(/daemon coverage map unavailable/, err)
  end

  def test_daemon_coverage_map_warns_when_unavailable
    cfg = config_for("order_test.rb")
    Mutineer::DaemonClient.stub(:new, ->(*) { raise Mutineer::DaemonBootError, "boom" }) do
      _out, err = capture_io do
        map = Mutineer::Runner.daemon_coverage_map(cfg, cfg.tests.map { |t| File.expand_path(t, cfg.project_root) })
        assert_nil map
      end
      assert_match(/daemon coverage map unavailable/, err)
    end
  end
end
