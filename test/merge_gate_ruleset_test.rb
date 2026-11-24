# frozen_string_literal: true

require "json"
require "yaml"
require "minitest/autorun"

# #355: .github/rulesets/main-merge-gate.json is the merge gate a maintainer
# applies to main. Each check it requires must be a check that CI reports, or
# no pull request could merge. Each CI job must be required, or a red job merges.
class MergeGateRulesetTest < Minitest::Test
  # The repository root.
  ROOT = File.expand_path("..", __dir__)
  # The GitHub Actions app. Its id pins each CI check to the app that reports it.
  ACTIONS_APP_ID = 15_368

  # The condition each CI job has, so a draft pull request starts no job.
  DRAFT_SKIP = "github.event_name != 'pull_request' || !github.event.pull_request.draft"

  # @return [Hash] the parsed CI workflow
  def ci
    YAML.load_file(File.join(ROOT, ".github/workflows/ci.yml"))
  end

  # @return [Hash] the parsed ruleset file
  def ruleset
    JSON.parse(File.read(File.join(ROOT, ".github/rulesets/main-merge-gate.json")))
  end

  # @param type [String] a rule type, such as "pull_request"
  # @return [Hash, nil] the parameters of that rule
  def rule(type)
    ruleset["rules"].find { |r| r["type"] == type }&.fetch("parameters", {})
  end

  # Every check name ci.yml reports on a pull request, with matrix values filled in.
  # @return [Array<String>]
  def ci_check_names
    ci["jobs"].flat_map do |id, job|
      name = job["name"] || id
      matrix_rows(job.dig("strategy", "matrix")).map do |row|
        name.gsub(/\$\{\{\s*matrix\.(\w+)\s*\}\}/) { row.fetch(Regexp.last_match(1)).to_s }
      end
    end
  end

  # GitHub's rules: exclude drops matching rows. An include entry extends each row
  # whose axis values it does not change, or becomes a new row when none fits.
  # @param matrix [Hash, nil] a job's strategy.matrix
  # @return [Array<Hash>] one Hash per matrix combination ([{}] without a matrix)
  def matrix_rows(matrix)
    return [{}] unless matrix

    axes = matrix.except("include", "exclude")
    rows = axes.reduce([{}]) { |acc, (key, values)| acc.product(values).map { |row, v| row.merge(key => v) } }
    rows.reject! { |row| Array(matrix["exclude"]).any? { |ex| ex.all? { |k, v| row[k] == v } } }
    original = rows.dup # an include never fits a row that another include added
    Array(matrix["include"]).each do |inc|
      fits = original.select { |row| inc.all? { |k, v| !axes.key?(k) || row[k] == v } }
      fits.empty? ? rows << inc : fits.each { |row| row.merge!(inc) }
    end
    rows
  end

  # Each ci.yml job name, with matrix values, is required, and nothing else from Actions.
  def test_every_ci_job_is_required_and_every_required_ci_check_exists
    checks = rule("required_status_checks")["required_status_checks"]
    actions = checks.select { |c| c["integration_id"] == ACTIONS_APP_ID }.map { |c| c["context"] }
    assert_equal ci_check_names.sort, actions.sort, "update .github/rulesets/main-merge-gate.json and re-apply it (docs/plans/2026-11-22-355-merge-gate-ruleset.md)"
    assert_includes actions, "test (ruby 4.0 on ubuntu-latest)", "a matrix include row is expanded"
    external = checks.reject { |c| c["integration_id"] == ACTIONS_APP_ID }.to_h { |c| [c["context"], c["integration_id"]] }
    assert_equal({ "GitGuardian Security Checks" => 46_505, "Socket Security: Pull Request Alerts" => 156_372 }, external)
  end

  # GitHub's matrix rules: exclude drops rows, an include extends or adds a row.
  def test_matrix_rows_follow_github_include_and_exclude
    matrix = { "os" => %w[a b], "include" => [{ "os" => "a", "extra" => 1 }, { "os" => "c" }, { "os" => "c", "x" => 2 }], "exclude" => [{ "os" => "b" }] }
    assert_equal [{ "os" => "a", "extra" => 1 }, { "os" => "c" }, { "os" => "c", "x" => 2 }], matrix_rows(matrix)
  end

  # The gate needs an up-to-date head and resolved threads, on main, for everyone.
  def test_the_gate_runs_on_the_head_commit_and_has_no_bypass
    assert_equal true, rule("required_status_checks")["strict_required_status_checks_policy"], "checks must run on a head that is up to date with main"
    assert_equal true, rule("pull_request")["required_review_thread_resolution"], "every review thread must be resolved"
    assert_empty ruleset["bypass_actors"], "branch protection lets an admin merge past it today; the ruleset must not"
    assert_equal ["~DEFAULT_BRANCH"], ruleset.dig("conditions", "ref_name", "include")
    assert_equal "active", ruleset["enforcement"]
  end

  # A draft pull request starts no job, and "ready for review" starts the run.
  # A change back to a draft starts a run too, so the group cancels the old one.
  # The condition is on each job, not on the workflow trigger: a ready pull
  # request then always starts the workflow, so its required checks report.
  def test_every_ci_job_skips_a_draft_and_ready_for_review_starts_the_run
    ci["jobs"].each { |id, job| assert_equal DRAFT_SKIP, job["if"], "job #{id} must skip a draft pull request" }
    # YAML reads the key `on` as true.
    types = (ci[true] || ci["on"]).dig("pull_request", "types")
    assert_equal %w[converted_to_draft opened ready_for_review reopened synchronize], types.sort, "the three defaults, and both draft changes"
  end

  # CI runs for a pull request into main or the 2.0 integration branch, and for
  # a push to either. Drop integration/v2.0 here when that branch is deleted
  # (AGENTS.md, "The 2.0 integration branch").
  def test_ci_runs_for_main_and_the_2_0_integration_branch
    on = ci[true] || ci["on"]
    assert_equal %w[main integration/v2.0], on.dig("push", "branches")
    assert_equal %w[main integration/v2.0], on.dig("pull_request", "branches")
  end

  # A push to a pull request cancels the run for its old commit. Every other run
  # (a push to main, the release dispatch) has no pull request number, so its
  # group is its own run id and no other run can cancel it.
  def test_a_new_push_cancels_only_the_run_of_the_same_pull_request
    assert_equal "ci-${{ github.event.pull_request.number || github.run_id }}", ci.dig("concurrency", "group")
    assert_equal true, ci.dig("concurrency", "cancel-in-progress")
  end
end
