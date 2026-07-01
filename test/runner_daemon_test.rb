# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/config"
require "mutineer/runner"

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
end
