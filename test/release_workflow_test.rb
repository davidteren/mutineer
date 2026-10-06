# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "open3"
require "tmpdir"
require "fileutils"

# #95: the release-PR workflow must ignore floating major tags (v1) and refuse
# a malformed next version. Runs the calculation block extracted from
# release-pr.yml against temporary Git histories. No push, no PR.
class ReleaseWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/release-pr.yml", __dir__)
  CALC_START = "# MUTINEER_VERSION_CALC_START"
  CALC_END = "# MUTINEER_VERSION_CALC_END"
  HELPERS_START = "# MUTINEER_RELEASE_HELPERS_START"
  HELPERS_END = "# MUTINEER_RELEASE_HELPERS_END"
  BOT = "41898282+github-actions[bot]@users.noreply.github.com"
  BOT_ENV = {
    "GIT_AUTHOR_NAME" => "github-actions[bot]", "GIT_AUTHOR_EMAIL" => BOT,
    "GIT_COMMITTER_NAME" => "github-actions[bot]", "GIT_COMMITTER_EMAIL" => BOT
  }.freeze
  HUMAN_ENV = {
    "GIT_AUTHOR_NAME" => "Human", "GIT_AUTHOR_EMAIL" => "human@example.com",
    "GIT_COMMITTER_NAME" => "Human", "GIT_COMMITTER_EMAIL" => "human@example.com"
  }.freeze

  def setup
    %w[bash git].each do |tool|
      skip "#{tool} not on PATH" unless system("command -v #{tool} >/dev/null 2>&1")
    end
  end

  def test_floating_major_tag_does_not_produce_invalid_patch
    with_history(tags: %w[v1.2.3 v1], extra_message: "fix: repair the gate") do |dir|
      out, err, status = run_calc(dir)
      assert_equal 0, status.exitstatus, "stderr:#{err}\nstdout:#{out}"
      assert_includes out, "latest_tag=v1.2.3"
      assert_includes out, "->  v1.2.4"
      refute_match(/v1\.\./, out)
    end
  end

  def test_feature_commit_bumps_minor
    with_history(tags: %w[v1.2.3 v1], extra_message: "feat: add a switch") do |dir|
      out, err, status = run_calc(dir)
      assert_equal 0, status.exitstatus, "stderr:#{err}\nstdout:#{out}"
      assert_includes out, "latest_tag=v1.2.3"
      assert_includes out, "->  v1.3.0"
    end
  end

  def test_no_complete_tag_exits_without_a_version
    with_history(tags: %w[v1], extra_message: "fix: something") do |dir|
      out, err, status = run_calc(dir)
      assert_equal 0, status.exitstatus, "stderr:#{err}\nstdout:#{out}"
      assert_match(/No complete vMAJOR\.MINOR\.PATCH tags/, out)
      refute_match(/->  v/, out)
    end
  end

  def test_malformed_tag_is_skipped_not_used
    with_history(tags: %w[v1.2.3 v1.2 v1.2.3-rc1], extra_message: "fix: skip junk tags") do |dir|
      out, err, status = run_calc(dir)
      assert_equal 0, status.exitstatus, "stderr:#{err}\nstdout:#{out}"
      assert_includes out, "latest_tag=v1.2.3"
      assert_includes out, "->  v1.2.4"
    end
  end

  def test_no_feat_or_fix_is_a_noop
    with_history(tags: %w[v1.2.3], extra_message: "docs: not a release") do |dir|
      out, err, status = run_calc(dir)
      assert_equal 0, status.exitstatus, "stderr:#{err}\nstdout:#{out}"
      assert_match(/nothing to release/, out)
    end
  end

  # Releases are batched (weekly + on demand): a merge to main must not open a
  # release PR by itself, and each run rebuilds the release branch from main.
  def test_release_prs_are_batched_not_opened_per_push
    triggers = YAML.load_file(WORKFLOW).then { |y| y[true] || y["on"] }
    assert_equal %w[schedule workflow_dispatch], triggers.keys.sort
    text = File.read(WORKFLOW)
    assert_includes text, 'git switch -C "$branch"', "the release branch must be rebuilt from main"
    refute_match(/git push --force(?!-with-lease)/, text, "never force-push the release branch (GITHUB_TOKEN may not)")
    assert_includes text, "--force-with-lease=", "the old release branch is deleted under a lease, never clobbered"
    assert_includes text, "gh pr edit", "an open release PR for the same version is refreshed"
    assert_includes text, "gh pr close", "an older open release PR is superseded"
    assert_includes text, "ls-remote --exit-code --tags", "an existing v<next> tag stops the run"
    assert_includes text, "token: ${{ secrets.RELEASE_PR_TOKEN", "git push must use the PAT so the rebuilt head gets CI"
    assert_equal "release-pr", YAML.load_file(WORKFLOW).dig("concurrency", "group"), "runs must not overlap"
  end

  # #85: a GITHUB_TOKEN push starts no CI, so the release PR's required checks never
  # ran. The job dispatches ci.yml on the release branch instead, unless a PAT is set.
  def test_release_pr_dispatches_ci_when_pushed_with_github_token
    workflow = YAML.load_file(WORKFLOW)
    assert_equal "write", workflow.dig("permissions", "actions"), "dispatching ci.yml needs actions: write"
    assert_includes File.read(WORKFLOW), 'dispatch_ci "$branch"'
    ci = YAML.load_file(File.expand_path("../.github/workflows/ci.yml", __dir__))
    assert_includes (ci[true] || ci["on"]).keys, "workflow_dispatch", "ci.yml must accept the dispatch"
  end

  def test_dispatch_ci_runs_ci_when_no_pat_and_no_dispatched_run
    out, calls = with_fake_gh(runs: "0") { |env| run_dispatch(env) }
    assert_match(/Dispatched ci.yml on release\/v9.9.9/, out)
    assert_includes calls, "workflow run ci.yml --ref release/v9.9.9"
  end

  def test_dispatch_ci_skips_when_a_dispatched_run_exists
    _, calls = with_fake_gh(runs: "1") { |env| run_dispatch(env) }
    refute(calls.any? { |c| c.start_with?("workflow run") }, "no second dispatch for the same head")
  end

  def test_dispatch_ci_skips_with_a_pat
    _, calls = with_fake_gh(runs: "0") { |env| run_dispatch(env.merge("HAS_RELEASE_PR_TOKEN" => "true")) }
    assert_empty calls, "a PAT push already started CI"
  end

  def test_dispatch_ci_reports_a_failed_dispatch
    out, = with_fake_gh(runs: "0", dispatch_exit: 1) { |env| run_dispatch(env, expect: 1) }
    assert_match(/::error::Could not dispatch ci.yml on release\/v9.9.9\. Run: gh workflow run ci.yml/, out)
  end

  def test_workflow_markers_wrap_the_live_calculation
    text = File.read(WORKFLOW)
    refute_nil text.index(CALC_START), "release-pr.yml needs #{CALC_START}"
    refute_nil text.index(CALC_END), "release-pr.yml needs #{CALC_END}"
    assert_includes version_calc_script, "git tag --list --sort=-v:refname"
    refute_match(/^latest_tag="\$\(git describe/, version_calc_script)
  end

  def test_bot_only_release_branch_has_no_human_commits
    result = human_work_on_release_branch? do |dir, git|
      commit(git, dir, BOT_ENV, "release: v1.2.4")
    end
    refute result
  end

  def test_human_commit_counts_as_human_work
    result = human_work_on_release_branch? do |dir, git|
      commit(git, dir, BOT_ENV, "release: v1.2.4")
      commit(git, dir, HUMAN_ENV, "fix typo in changelog")
    end
    assert result
  end

  def test_bot_commit_amended_by_a_human_counts_as_human_work
    amended = BOT_ENV.merge("GIT_COMMITTER_NAME" => "Human", "GIT_COMMITTER_EMAIL" => "human@example.com")
    result = human_work_on_release_branch? do |dir, git|
      commit(git, dir, amended, "release: v1.2.4")
    end
    assert result
  end

  # GitHub's "Update branch" merges main into the release branch as a person.
  def test_human_merge_commit_counts_as_human_work
    result = human_work_on_release_branch? do |dir, git|
      commit(git, dir, BOT_ENV, "release: v1.2.4")
      git.call("switch", "-q", "main")
      commit(git, dir, HUMAN_ENV, "fix: more work on main", push: "main", file: "README")
      git.call("switch", "-q", "release/v1.2.4")
      system(HUMAN_ENV, "git", "-c", "core.hooksPath=/dev/null", "merge", "-q", "--no-ff", "-m", "Merge main",
             "main", chdir: dir, exception: true)
      git.call("push", "-q", "origin", "release/v1.2.4")
    end
    assert result
  end

  def test_version_guard_proceeds_when_version_is_the_latest_tag
    assert_equal "no", run_helpers("untagged_bump 1.2.3 v1.2.3 && echo yes || echo no")
  end

  def test_version_guard_stops_on_an_untagged_bump
    assert_equal "yes", run_helpers("untagged_bump 1.3.0 v1.2.3 && echo yes || echo no")
    assert_equal "yes", run_helpers("untagged_bump 2.0.0 v1.2.3 && echo yes || echo no")
  end

  def test_supersede_compares_versions_numerically
    assert_equal "yes", run_helpers("version_lt 1.2.9 1.2.10 && echo yes || echo no")
    assert_equal "no", run_helpers("version_lt 2.0.0 1.3.0 && echo yes || echo no")
    assert_equal "no", run_helpers("version_lt 1.3.0 1.3.0 && echo yes || echo no")
  end

  private

  # Extracts the marked calculation block from the workflow, dropping YAML indent.
  #
  # @return [String] bash script text.
  def version_calc_script
    marked_block(CALC_START, CALC_END)
  end

  # Extracts the marked helper functions from the workflow, dropping YAML indent.
  #
  # @return [String] bash script text.
  def helpers_script
    marked_block(HELPERS_START, HELPERS_END)
  end

  # @return [String] the workflow text between two marker comments, unindented.
  def marked_block(start_marker, end_marker)
    text = File.read(WORKFLOW)
    start = text.index(start_marker)
    finish = text.index(end_marker)
    raise "#{start_marker} / #{end_marker} missing from #{WORKFLOW}" unless start && finish

    text[start..finish].lines.map { |line| line.sub(/^          /, "") }.join
  end

  # Puts a fake `gh` first on PATH that logs its arguments, prints `runs` for
  # `gh run list`, and exits `dispatch_exit` for `gh workflow run`.
  #
  # @return [Array(String, Array<String>)] the block's stdout and the gh calls.
  def with_fake_gh(runs:, dispatch_exit: 0)
    Dir.mktmpdir do |dir|
      log = File.join(dir, "calls.log")
      File.write(File.join(dir, "gh"), <<~SH)
        #!/bin/bash
        echo "$*" >> #{log}
        [ "$1 $2" = "run list" ] && { echo #{runs}; exit 0; }
        exit #{dispatch_exit}
      SH
      File.chmod(0o755, File.join(dir, "gh"))
      out = yield("PATH" => "#{dir}:#{ENV.fetch("PATH")}")
      [out, File.exist?(log) ? File.readlines(log, chomp: true) : []]
    end
  end

  # Runs `dispatch_ci` from the workflow helpers with `env`; returns stdout.
  #
  # @param env [Hash{String=>String}]
  # @param expect [Integer] the exit status the helper must return.
  # @return [String]
  def run_dispatch(env, expect: 0)
    out, err, status = Open3.capture3(env, "bash", "-uo", "pipefail", "-c",
                                      "#{helpers_script}\ndispatch_ci release/v9.9.9 abc123")
    assert_equal expect, status.exitstatus, "stderr:#{err}\nstdout:#{out}"
    out
  end

  # Runs the helpers, then `snippet`, in `dir`; returns stripped stdout.
  #
  # @param snippet [String] bash that calls a helper.
  # @param dir [String] working directory.
  # @return [String]
  def run_helpers(snippet, dir: Dir.pwd)
    out, err, status = Open3.capture3("bash", "-euo", "pipefail", "-c", "#{helpers_script}\n#{snippet}", chdir: dir)
    assert_equal 0, status.exitstatus, "stderr:#{err}\nstdout:#{out}"
    out.strip
  end

  # Commits a change as the identity in `env` and pushes `push` to origin.
  def commit(git, dir, env, message, push: "release/v1.2.4", file: "CHANGELOG")
    File.write(File.join(dir, file), "#{message}\n", mode: "a")
    git.call("add", file)
    system(env, "git", "-c", "core.hooksPath=/dev/null", "commit", "-qm", message, chdir: dir, exception: true)
    git.call("push", "-q", "origin", push)
  end

  # Builds a bare "origin" and a clone, branches release/v1.2.4 from main, lets the
  # block commit onto it, then runs has_human_commits from main after fetching the
  # release refs the way the workflow does.
  #
  # @yieldparam dir [String] clone path (on release/v1.2.4).
  # @yieldparam git [Proc] runs git in the clone.
  # @return [Boolean] true when has_human_commits reports human work.
  def human_work_on_release_branch?
    root = Dir.mktmpdir("mutineer-release-helpers")
    origin = File.join(root, "origin.git")
    dir = File.join(root, "work")
    system("git", "init", "-q", "--bare", origin, exception: true)
    # A push runs auto-maintenance in the bare repo without the suite's
    # GIT_CONFIG_* env (see test_helper.rb, #174), so turn it off here too.
    system("git", "-C", origin, "config", "maintenance.auto", "false", exception: true)
    system("git", "clone", "-q", origin, dir, exception: true, err: File::NULL)
    git = lambda do |*args|
      system("git", "-c", "core.hooksPath=/dev/null", *args, chdir: dir, exception: true)
    end
    git.call("config", "user.email", "release-test@example.com")
    git.call("config", "user.name", "Release Test")
    git.call("switch", "-q", "-c", "main")
    File.write(File.join(dir, "README"), "base\n")
    git.call("add", "README")
    git.call("commit", "-qm", "chore: initial")
    git.call("push", "-q", "origin", "main")
    git.call("switch", "-q", "-c", "release/v1.2.4")
    yield dir, git
    git.call("switch", "-q", "main")
    git.call("fetch", "-q", "origin", "+refs/heads/release/*:refs/remotes/origin/release/*")
    run_helpers("has_human_commits release/v1.2.4 && echo yes || echo no", dir: dir) == "yes"
  ensure
    FileUtils.rm_rf(root) if root # rm_rf: backstop for a git process still writing here (#174)
  end

  # Runs the extracted calculation in `dir`.
  #
  # @param dir [String] git repository path.
  # @return [Array(String, String, Process::Status)]
  def run_calc(dir)
    Open3.capture3("bash", "-euo", "pipefail", "-c", version_calc_script, chdir: dir)
  end

  # A tiny git repo with a tagged base commit plus one extra commit.
  #
  # @param tags [Array<String>] tags to apply to the base commit.
  # @param extra_message [String] subject of the follow-up commit.
  # @yieldparam dir [String] repository path.
  def with_history(tags:, extra_message:)
    dir = Dir.mktmpdir("mutineer-release-calc")
    begin
      git = lambda do |*args|
        system("git", "-c", "core.hooksPath=/dev/null", *args, chdir: dir, exception: true)
      end
      git.call("init", "-q")
      git.call("config", "user.email", "release-test@example.com")
      git.call("config", "user.name", "Release Test")
      File.write(File.join(dir, "README"), "base\n")
      git.call("add", "README")
      git.call("commit", "-qm", "chore: initial")
      tags.each { |tag| git.call("tag", tag) }
      File.write(File.join(dir, "README"), "next\n")
      git.call("add", "README")
      git.call("commit", "-qm", extra_message)
      yield dir
    ensure
      FileUtils.rm_rf(dir) # rm_rf: backstop for a git process still writing here (#174)
    end
  end
end
