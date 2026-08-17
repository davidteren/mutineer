# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# End-to-end harness for action.yml's run script: test/fixtures/action_harness.sh
# extracts the script from the YAML and executes it the way GitHub does
# (bash -e -o pipefail) against a stub mutineer binary. Scenarios cover the
# PR-base resolution chain (event-payload sha, branch-tip fallback,
# pull_request_target guard, since: none), report freshness vs staleness,
# summary/annotation rendering (workflow-command escaping included), and the
# extra-args --format/--output guard.
class ActionHarnessTest < Minitest::Test
  HARNESS = File.expand_path("fixtures/action_harness.sh", __dir__)

  def test_action_run_script_scenarios
    %w[bash git jq].each do |tool|
      skip "#{tool} not on PATH" unless system("command -v #{tool} >/dev/null 2>&1")
    end
    out, err, status = Open3.capture3("bash", HARNESS)
    assert status.success?, "harness exited #{status.exitstatus}\nstdout:\n#{out}\nstderr:\n#{err}"
    refute_match(/FAIL:/, out, "harness reported failures:\n#{out}")

    { "case1" => 1, "case2" => 0, "case3" => 1, "case3b" => 1, "case4" => 1,
      "case5" => 1, "case6" => 2, "case7" => 1, "case8" => 2, "case8b" => 2, "case9" => 0 }.each do |c, code|
      assert_includes out, "#{c}: exit=#{code}", "#{c} exit code drifted:\n#{out}"
    end
    assert_includes out, "OK: abbreviation rejected"
    assert_includes out, "OK: caller output delivered"
    assert_includes out, "OK: report output names caller path"
    assert_includes out, "OK: scoped to base.sha"
    assert_includes out, "OK: stale file NOT deleted (baseline-safe)"
    assert_includes out, "OK: rejected before running"
    assert_includes out, "--no-since", "since: none must pass --no-since through"
    assert_includes out, "::error file=lib/we%2Cird%3Aname.rb", "property escaping regressed"
  end
end
