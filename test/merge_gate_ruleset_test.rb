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
    jobs = YAML.load_file(File.join(ROOT, ".github/workflows/ci.yml"))["jobs"]
    jobs.flat_map do |id, job|
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
end
