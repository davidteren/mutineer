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
    assert_includes out, "OK: passing-run warnings"
    assert_includes out, "OK: no errors on passing run"
    assert_includes out, "::error file=lib/we%2Cird%3Aname.rb", "property escaping regressed"
    assert_includes out, "100%25", "msg percent-escaping of the survivor token regressed"
    refute_match(/::(?:error|warning)[^\n]*<\n/, out, "msg must collapse newlines in the survivor token")

    # Exit codes alone cannot discriminate the scoping scenarios (a regressed
    # branch keeps the same code), so assert each case's decisive line.
    sections = out.split(/^== /)
    sec = ->(prefix) do
      sections.find { |x| x.start_with?(prefix) } || flunk("missing section #{prefix}:\n#{out}")
    end
    # Compare against the invocation line only: the section TITLES name the
    # flags they are about, so matching the whole section would self-trigger.
    args_of = ->(prefix) { sec.call(prefix)[/STUB-ARGS:.*/] || "" }
    assert_includes args_of.call("3b:"), "--since origin/main", "branch-tip fallback regressed"
    refute_includes args_of.call("4:"), "--since", "pull_request_target must not be scoped"
    assert_includes args_of.call("5:"), "--no-since", "since: none must pass --no-since through"
    refute_includes args_of.call("5:"), "--since origin", "since: none must not also scope"
    assert_includes sec.call("7:"), "file=sub/lib/calc.rb", "working-directory prefix regressed"
  end
end
