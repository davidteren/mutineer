# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "open3"
require "tmpdir"
require "fileutils"
require "json"

# #95: the release-PR workflow must ignore floating major tags (v1) and refuse
# a malformed next version. Runs the calculation block extracted from
# release-pr.yml against temporary Git histories. No push, no PR.
class ReleaseWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/release-pr.yml", __dir__)
  CALC_START = "# MUTINEER_VERSION_CALC_START"
  CALC_END = "# MUTINEER_VERSION_CALC_END"
  HELPERS_START = "# MUTINEER_RELEASE_HELPERS_START"
  HELPERS_END = "# MUTINEER_RELEASE_HELPERS_END"
  RELEASE_WORKFLOW = File.expand_path("../.github/workflows/release.yml", __dir__)
  STABLE_TAG_START = "# MUTINEER_STABLE_TAG_START"
  STABLE_TAG_END = "# MUTINEER_STABLE_TAG_END"
  PUBLISH_GATE_START = "# MUTINEER_PUBLISH_GATE_START"
  PUBLISH_GATE_END = "# MUTINEER_PUBLISH_GATE_END"
  ACTOR_START = "# MUTINEER_RELEASE_ACTOR_START"
  ACTOR_END = "# MUTINEER_RELEASE_ACTOR_END"
  ENV_GATE_START = "# MUTINEER_ENV_GATE_START"
  ENV_GATE_END = "# MUTINEER_ENV_GATE_END"
  TAG_COMMIT_START = "# MUTINEER_TAG_COMMIT_START"
  TAG_COMMIT_END = "# MUTINEER_TAG_COMMIT_END"
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

  # A merge to main must not open a release PR, and nothing on a schedule may
  # open one either. Each manual run still rebuilds the release branch from main.
  def test_release_prs_are_opened_only_by_a_manual_dispatch
    triggers = YAML.load_file(WORKFLOW).then { |y| y[true] || y["on"] }
    assert_equal %w[workflow_dispatch], triggers.keys
    text = File.read(WORKFLOW)
    refute_match(/cron:/, text, "a cron would open a release PR with no one deciding")
    refute_match(/^[ \t]*schedule:/, text, "release-pr.yml must not declare a schedule")
    assert_includes text, "collaborators/${actor}/permission", "the actor's permission is read at runtime"
    assert_includes text, 'GITHUB_EVENT_NAME:-}" != "workflow_dispatch"', "a schedule event is attributed to the last editor, so the event is part of the guard"
    assert_includes text, 'git switch -C "$branch"', "the release branch must be rebuilt from main"
    refute_includes text, "tests and publishes", "the release PR must not tell anyone that a tag publishes"
    assert_includes text, "RELEASE_PR_MARKER_PREVIOUS='Auto-opened by `release-pr.yml`'", "an already-open release PR still uses the previous marker"
    assert_equal 3, text.scan("contains(env.RELEASE_PR_MARKER_PREVIOUS)").length
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

  # #161: the release trigger glob v*.*.* also matches prereleases. Only a
  # stable vMAJOR.MINOR.PATCH tag may publish and get a floating-tag command.
  def test_release_guard_accepts_a_stable_tag
    out, status = run_stable_tag_guard("v1.3.1")
    assert_equal 0, status.exitstatus, out
  end

  def test_release_guard_refuses_a_prerelease_tag
    out, status = run_stable_tag_guard("v1.3.1-rc1")
    assert_equal 1, status.exitstatus
    assert_match(/::error::Tag v1\.3\.1-rc1 is not a stable vMAJOR\.MINOR\.PATCH tag/, out)
  end

  def test_release_guard_refuses_a_malformed_tag
    %w[v1.2.3.4 v1.2 vx.y.z].each do |tag|
      out, status = run_stable_tag_guard(tag)
      assert_equal 1, status.exitstatus, tag
      assert_match(/::error::Tag #{Regexp.escape(tag)} is not a stable/, out)
    end
  end

  # The maintainer gate, the stable-tag guard, and the moved-tag guard run
  # before anything publishes.
  def test_release_guard_runs_before_publishing
    steps = YAML.load_file(RELEASE_WORKFLOW).dig("jobs", "release", "steps").map { |s| "#{s["uses"]}#{s["run"]}" }
    actor = steps.index { |s| s.include?(ACTOR_START) }
    gate = steps.index { |s| s.include?(PUBLISH_GATE_START) }
    guard = steps.index { |s| s.include?(STABLE_TAG_START) }
    tag_commit = steps.index { |s| s.include?(TAG_COMMIT_START) }
    refute_nil actor, "release.yml needs #{ACTOR_START} on the publish job"
    refute_nil gate, "release.yml needs #{PUBLISH_GATE_START}"
    refute_nil guard, "release.yml needs #{STABLE_TAG_START}"
    refute_nil tag_commit, "release.yml needs #{TAG_COMMIT_START}"
    assert_operator actor, :<, gate, "the permission check runs before the confirm-word check"
    assert_operator gate, :<, guard, "the confirm-word check runs before the version check"
    assert_operator guard, :<, tag_commit, "the tag name is validated before it is fetched"
    ["configure-rubygems-credentials", "gem push", "gh release create"].each do |marker|
      step = steps.index { |s| s.include?(marker) }
      refute_nil step, marker
      assert_operator guard, :<, step, "the stable-tag guard must run before #{marker}"
      assert_operator tag_commit, :<, step, "the moved-tag guard must run before #{marker}"
    end
  end

  # The environment approval can wait for days. A tag moved in that time must
  # not change what publishes, so the job builds the dispatched commit.
  def test_publish_builds_the_dispatched_commit
    release = YAML.load_file(RELEASE_WORKFLOW).dig("jobs", "release")
    checkout = release["steps"].find { |s| s["uses"].to_s.start_with?("actions/checkout") }
    assert_equal "${{ github.sha }}", checkout.dig("with", "ref")
    text = File.read(RELEASE_WORKFLOW)
    assert_includes text, '--verify-tag --target "$GITHUB_SHA"'
    assert_includes text, "GITHUB_STEP_SUMMARY", "a green run must still show the tag move that is left"
    assert_includes text, "git tag -f ${major} ${GITHUB_SHA}", "the printed command names the built commit"
    refute_match(/^\s*git push/, text, "a ruleset keeps the floating tag for maintainers; the job never pushes a tag")
  end

  def test_tag_commit_guard_accepts_an_unmoved_tag
    with_tagged_origin do |clone, first, _second|
      out, status = run_tag_commit_guard(clone, first)
      assert_equal 0, status.exitstatus, out
    end
  end

  def test_tag_commit_guard_refuses_a_deleted_tag
    with_tagged_origin(delete: true) do |clone, first, _second|
      out, status = run_tag_commit_guard(clone, first)
      assert_equal 1, status.exitstatus
      assert_match(/Tag v1\.2\.3 is gone from origin since dispatch/, out)
    end
  end

  def test_tag_commit_guard_refuses_a_moved_tag
    with_tagged_origin(move: true) do |clone, first, second|
      out, status = run_tag_commit_guard(clone, first)
      assert_equal 1, status.exitstatus
      assert_match(/Tag v1\.2\.3 now points at #{second}, but this run was dispatched on #{first}/, out)
    end
  end

  # GitHub creates a missing environment with no reviewers, and the publish
  # job would then run unapproved. The authorize job refuses that state.
  def test_env_gate_accepts_an_environment_with_reviewers
    reviewer = { "type" => "User", "reviewer" => { "login" => "maintainer" } }
    rules = [{ "type" => "branch_policy" }, { "type" => "required_reviewers", "reviewers" => [reviewer] }]
    out, status, calls = run_env_gate({ "can_admins_bypass" => false, "protection_rules" => rules })
    assert_equal 0, status.exitstatus, out
    assert_includes calls.first, "repos/example/mutineer/environments/rubygems"
  end

  def test_env_gate_refuses_an_environment_without_reviewers
    [
      {}, { "protection_rules" => [] }, { "protection_rules" => [{ "type" => "wait_timer" }] },
      { "protection_rules" => [{ "type" => "required_reviewers", "reviewers" => [] }] }
    ].each do |body|
      out, status, = run_env_gate(body.merge("can_admins_bypass" => false))
      assert_equal 1, status.exitstatus, body.inspect
      assert_match(/has no required reviewers/, out)
    end
  end

  def test_env_gate_refuses_when_admins_can_bypass
    rules = [{ "type" => "required_reviewers", "reviewers" => [{ "type" => "User" }] }]
    [{ "can_admins_bypass" => true }, {}].each do |bypass|
      out, status, = run_env_gate(bypass.merge("protection_rules" => rules))
      assert_equal 1, status.exitstatus, bypass.inspect
      assert_match(/Administrators can bypass/, out)
    end
  end

  def test_env_gate_refuses_a_missing_environment
    out, status, = run_env_gate({}, fail: true)
    assert_equal 1, status.exitstatus
    assert_match(/Could not read the rubygems environment/, out)
  end

  def test_env_gate_runs_in_authorize_before_the_publish_job
    authorize = YAML.load_file(RELEASE_WORKFLOW).dig("jobs", "authorize")
    assert_equal "read", authorize.dig("permissions", "actions"), "reading an environment needs actions: read"
    assert(authorize["steps"].any? { |s| s["run"].to_s.include?(ENV_GATE_START) })
  end

  # Tag pushes and the Monday cron used to publish with no second decision.
  # Publish is a manual workflow_dispatch by a human maintainer, then the
  # rubygems environment. Required reviewers are a GitHub setting; the
  # workflow names the environment so that setting has a job to hold.
  def test_publish_is_a_manual_dispatch_gated_on_the_maintainer
    workflow = YAML.load_file(RELEASE_WORKFLOW)
    triggers = workflow[true] || workflow["on"]
    assert_equal %w[workflow_dispatch], triggers.keys
    assert_equal true, triggers.dig("workflow_dispatch", "inputs", "confirm", "required")
    release = workflow.dig("jobs", "release")
    assert_equal ["authorize"], release["needs"]
    assert_equal "rubygems", release.dig("environment", "name")
    assert_includes release["if"], "needs.authorize.result == 'success'"
    assert_includes release["if"], "github.event_name == 'workflow_dispatch'"
    assert_includes release["if"], "github.event.inputs.confirm == 'publish'"
    assert_includes release["if"], "startsWith(github.ref, 'refs/tags/v')"
    refute_includes release["if"], "github.actor"
    assert_equal "write", release.dig("permissions", "id-token")
    assert_equal "write", release.dig("permissions", "contents")
    authorize = workflow.dig("jobs", "authorize")
    refute_nil authorize
    assert_equal "read", authorize.dig("permissions", "contents")
    assert_nil authorize.dig("permissions", "id-token")
    assert_nil authorize["environment"], "permission is checked before the environment is requested"
    refuse = workflow.dig("jobs", "refuse")
    refute_nil refuse, "a refused publish must fail the workflow, so the skip is visible"
    assert_nil refuse.dig("permissions", "id-token"), "the refuse job must not be able to mint RubyGems credentials"
    assert_equal "none", refuse.dig("permissions", "contents")
    refute_includes refuse["if"], "github.actor"
    assert_includes refuse["if"], "github.event_name != 'workflow_dispatch'"
    assert_includes refuse["if"], "github.event.inputs.confirm != 'publish'"
    assert_includes refuse["if"], "!startsWith(github.ref, 'refs/tags/v')"
    assert_includes authorize["if"], "github.event_name == 'workflow_dispatch'"
    assert_includes authorize["if"], "github.event.inputs.confirm == 'publish'"
    assert_includes authorize["if"], "startsWith(github.ref, 'refs/tags/v')"
    text = File.read(RELEASE_WORKFLOW)
    refute_match(/^[ \t]*schedule:/, text)
    refute_match(/workflow_run:/, text)
    refute_match(/^[ \t]*push:/, text)
    refute_includes text, "tags:"
    assert_equal 2, text.scan(ACTOR_START).length, "authorize and the publish job both check the actor"
  end

  def test_gem_push_lives_only_in_the_manual_release_workflow
    paths = Dir[File.expand_path("../.github/workflows/*.yml", __dir__)]
    pushers = paths.select { |path| File.read(path).include?("gem push") }
    assert_equal [RELEASE_WORKFLOW], pushers.map { |path| File.expand_path(path) }
  end

  def test_publish_gate_accepts_a_confirmed_dispatch_on_a_tag
    out, status = run_publish_gate(event: "workflow_dispatch", ref: "refs/tags/v1.2.3", confirm: "publish")
    assert_equal 0, status.exitstatus, out
  end

  # The Monday cron's actor can be a maintainer. The event check is what stops it.
  def test_publish_gate_refuses_a_schedule
    out, status = run_publish_gate(event: "schedule", ref: "refs/tags/v1.2.3", confirm: "publish")
    assert_equal 1, status.exitstatus
    assert_match(/A tag push does not publish/, out)
  end

  def test_publish_gate_refuses_a_tag_push
    out, status = run_publish_gate(event: "push", ref: "refs/tags/v1.2.3", confirm: "publish")
    assert_equal 1, status.exitstatus
    assert_match(/A tag push does not publish/, out)
  end

  # The tests run the first copy. Every other copy must match it, including
  # the one in the publish job, which holds id-token and the environment.
  def test_release_actor_check_is_the_same_in_every_job
    copies = marked_blocks(ACTOR_START, ACTOR_END, workflow: RELEASE_WORKFLOW) +
             marked_blocks(ACTOR_START, ACTOR_END, workflow: WORKFLOW)
    assert_equal 3, copies.length, "authorize, the publish job, and release-pr.yml"
    assert_equal [copies.first], copies.uniq
    release = copies.first
    assert_includes release, 'actor="${GITHUB_TRIGGERING_ACTOR:-}"'
    refute_includes release, "mapfile", "macOS bash 3.2 has no mapfile"
    assert_includes release, ".user.permissions.maintain"
    assert_includes release, ".user.permissions.admin"
    assert_includes release, '.role_name // ""'
  end

  # Each accepted path on its own: the admin flag, the maintain flag, and
  # role_name for a response without the flags.
  def test_release_actor_accepts_admin_and_maintain
    [
      { admin: true, maintain: false, role: "write" },
      { admin: false, maintain: true, role: "write" },
      { admin: nil, maintain: nil, role: "admin" },
      { admin: nil, maintain: nil, role: "maintain" }
    ].each do |grant|
      out, status, calls = run_release_actor(actor: "maintainer", **grant)
      assert_equal 0, status.exitstatus, "#{grant.inspect}\n#{out}"
      assert calls.any? { |call| call.include?("collaborators/maintainer/permission") }, calls.inspect
    end
  end

  # The legacy permission field reports maintain as write. The maintain flag is what counts.
  def test_release_actor_accepts_a_custom_role_that_grants_maintain
    out, status, = run_release_actor(actor: "maintainer", admin: false, maintain: true, role: "shippers")
    assert_equal 0, status.exitstatus, out
  end

  def test_release_actor_refuses_write_triage_and_read
    %w[write triage read].each do |role|
      out, status, = run_release_actor(actor: "contributor", admin: false, maintain: false, role: role)
      assert_equal 1, status.exitstatus, role
      assert_match(/does not have maintain or admin/, out)
    end
  end

  # A rerun keeps github.actor as the original maintainer. The person who
  # clicked rerun is github.triggering_actor, and that person needs maintain.
  def test_release_actor_refuses_a_rerun_by_someone_without_maintain
    out, status, calls = run_release_actor(actor: "original-maintainer", triggering_actor: "writer",
                                            admin: false, maintain: false, role: "write")
    assert_equal 1, status.exitstatus
    assert_match(/does not have maintain or admin/, out)
    assert calls.any? { |call| call.include?("collaborators/writer/permission") }, calls.inspect
    refute calls.any? { |call| call.include?("collaborators/original-maintainer/permission") }
  end

  def test_release_actor_refuses_when_the_triggering_actor_is_missing
    out, status, calls = run_release_actor(actor: "original-maintainer", triggering_actor: "")
    assert_equal 1, status.exitstatus
    assert_match(/triggering_actor is empty/, out)
    assert_empty calls
  end

  def test_release_actor_refuses_a_bot_login_without_calling_the_api
    _out, status, calls = run_release_actor(actor: "github-actions[bot]", admin: true, maintain: true, role: "admin")
    assert_equal 1, status.exitstatus
    assert_empty calls
  end

  def test_release_actor_refuses_a_bot_account_type
    out, status, = run_release_actor(actor: "some-app", kind: "Bot", admin: true, maintain: true, role: "admin")
    assert_equal 1, status.exitstatus
    assert_match(/type Bot/, out)
  end

  def test_release_actor_refuses_a_schedule_without_calling_the_api
    out, status, calls = run_release_actor(event: "schedule", actor: "maintainer", admin: true, maintain: true, role: "admin")
    assert_equal 1, status.exitstatus
    assert_match(/A schedule does not start a release/, out)
    assert_empty calls
  end

  def test_release_actor_refuses_when_the_permission_api_fails
    out, status, = run_release_actor(actor: "maintainer", fail: true)
    assert_equal 1, status.exitstatus
    assert_match(/Could not read repository permission/, out)
  end

  def test_agent_docs_forbid_releasing
    root = File.expand_path("..", __dir__)
    agents = File.read(File.join(root, "AGENTS.md"))
    claude = File.read(File.join(root, "CLAUDE.md"))
    contributing = File.read(File.join(root, "CONTRIBUTING.md"))
    stability = File.read(File.join(root, "STABILITY.md"))
    [agents, claude, contributing].each do |text|
      assert_includes text, "maintain or admin"
      assert_match(/gem push/, text)
    end
    [
      "AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "STABILITY.md",
      ".github/workflows/release.yml", ".github/workflows/release-pr.yml"
    ].each do |rel|
      refute_includes File.read(File.join(root, rel)), "davidteren", "#{rel} must not name a person"
    end
    refute_includes agents, "this is the whole release trigger"
    refute_includes agents, "no environment"
    assert_includes agents, "environment name to `rubygems`"
    assert_includes agents, "Prevent self-review"
    assert_includes agents, "release-maintainers"
    assert_includes agents, "workflow_dispatch"
    refute_includes stability, "weekly release pull request stays"
    assert_includes stability, "There is no weekly release pull request."
    assert_includes claude, "release.yml"
    assert_includes claude, "rubygems"
  end

  def test_publish_gate_refuses_a_branch_and_a_missing_confirm_word
    branch, branch_status = run_publish_gate(event: "workflow_dispatch", ref: "refs/heads/main", confirm: "publish")
    assert_equal 1, branch_status.exitstatus
    assert_match(/Pushing the tag does not publish/, branch)
    word, word_status = run_publish_gate(event: "workflow_dispatch", ref: "refs/tags/v1.2.3", confirm: "yes")
    assert_equal 1, word_status.exitstatus
    assert_match(/confirm=publish/, word)
  end

  private

  # Runs the maintainer publish gate extracted from release.yml.
  #
  # @param event [String] GITHUB_EVENT_NAME
  # @param ref [String] GITHUB_REF
  # @param confirm [String] the workflow_dispatch confirm input
  # @return [Array(String, Process::Status)] combined output and exit status
  def run_publish_gate(event:, ref:, confirm:)
    script = marked_block(PUBLISH_GATE_START, PUBLISH_GATE_END, workflow: RELEASE_WORKFLOW)
    env = { "GITHUB_EVENT_NAME" => event, "GITHUB_REF" => ref, "CONFIRM" => confirm }
    out, err, status = Open3.capture3(env, "bash", "-euo", "pipefail", "-c", script)
    ["#{out}#{err}", status]
  end

  # Runs the permission check against a collaborator-permission response.
  # The fake `gh` applies the workflow's own --jq filter with jq.
  #
  # @param event [String]
  # @param actor [String] GITHUB_ACTOR, the original dispatcher
  # @param triggering_actor [String, nil] who started this attempt; defaults to actor
  # @param kind [String] GitHub user.type
  # @param admin [Boolean, nil] user.permissions.admin; nil omits the flags
  # @param maintain [Boolean, nil] user.permissions.maintain; nil omits the flags
  # @param role [String] role_name
  # @param fail [Boolean] when the API call exits 1
  # @return [Array(String, Process::Status, Array<String>)] output, status, gh calls
  def run_release_actor(event: "workflow_dispatch", actor: "maintainer", triggering_actor: nil, kind: "User",
                        admin: false, maintain: false, role: "write", fail: false)
    triggering_actor = actor if triggering_actor.nil?
    user = { "login" => triggering_actor, "type" => kind }
    user["permissions"] = { "admin" => admin, "maintain" => maintain, "push" => true } unless admin.nil? && maintain.nil?
    script = marked_block(ACTOR_START, ACTOR_END, workflow: RELEASE_WORKFLOW)
    env = { "GITHUB_EVENT_NAME" => event, "GITHUB_ACTOR" => actor, "GITHUB_TRIGGERING_ACTOR" => triggering_actor }
    run_with_fake_api(script, { "permission" => "write", "role_name" => role, "user" => user }, env, fail: fail)
  end

  # Runs the environment check from the authorize job against `body`.
  #
  # @param body [Hash] the environment API response
  # @param fail [Boolean] when the API call exits 1 (a missing environment)
  # @return [Array(String, Process::Status, Array<String>)] output, status, gh calls
  def run_env_gate(body, fail: false)
    run_with_fake_api(marked_block(ENV_GATE_START, ENV_GATE_END, workflow: RELEASE_WORKFLOW), body, {}, fail: fail)
  end

  # Runs `script` with a fake `gh api` that logs its arguments and prints
  # `body` through the caller's --jq filter, as the real gh does.
  #
  # @param script [String] bash extracted from a workflow
  # @param body [Hash] the API response
  # @param env [Hash{String=>String}] extra environment
  # @param fail [Boolean] when the API call exits 1
  # @return [Array(String, Process::Status, Array<String>)] output, status, gh calls
  def run_with_fake_api(script, body, env, fail: false)
    skip "jq not on PATH" unless system("command -v jq >/dev/null 2>&1")
    Dir.mktmpdir do |dir|
      log = File.join(dir, "calls.log")
      json = File.join(dir, "body.json")
      File.write(json, JSON.generate(body))
      File.write(File.join(dir, "gh"), <<~SH)
        #!/bin/bash
        echo "$*" >> #{log}
        [ "$1" = "api" ] || exit 1
        [ "${FAIL}" = "1" ] && exit 1
        filter="."
        while [ $# -gt 0 ]; do
          [ "$1" = "--jq" ] && filter="$2"
          shift
        done
        jq -r "$filter" #{json}
      SH
      File.chmod(0o755, File.join(dir, "gh"))
      env = env.merge("PATH" => "#{dir}:#{ENV.fetch("PATH")}", "GITHUB_REPOSITORY" => "example/mutineer",
                      "FAIL" => fail ? "1" : "0")
      out, err, status = Open3.capture3(env, "bash", "-euo", "pipefail", "-c", script)
      calls = File.exist?(log) ? File.readlines(log, chomp: true) : []
      ["#{out}#{err}", status, calls]
    end
  end

  # Runs the moved-tag guard in `clone` as if the run was dispatched on `sha`.
  #
  # @param clone [String] a clone of the tagged origin
  # @param sha [String] GITHUB_SHA
  # @return [Array(String, Process::Status)] combined output and exit status
  def run_tag_commit_guard(clone, sha)
    script = marked_block(TAG_COMMIT_START, TAG_COMMIT_END, workflow: RELEASE_WORKFLOW)
    env = { "GITHUB_REF_NAME" => "v1.2.3", "GITHUB_SHA" => sha }
    out, err, status = Open3.capture3(env, "bash", "-euo", "pipefail", "-c", script, chdir: clone)
    ["#{out}#{err}", status]
  end

  # An origin with two commits and an annotated tag v1.2.3 on the first, and
  # a clone of it. With `move`, the tag is then moved to the second commit.
  # With `delete`, the tag is then deleted from the origin.
  #
  # @yieldparam clone [String] the clone path
  # @yieldparam first [String] the first commit SHA
  # @yieldparam second [String] the second commit SHA
  def with_tagged_origin(move: false, delete: false)
    root = Dir.mktmpdir("mutineer-release-tag")
    origin = File.join(root, "origin")
    clone = File.join(root, "clone")
    git = ->(*args) { system("git", "-c", "core.hooksPath=/dev/null", *args, chdir: origin, exception: true) }
    system("git", "init", "-q", origin, exception: true)
    git.call("config", "user.email", "release-test@example.com")
    git.call("config", "user.name", "Release Test")
    shas = %w[first second].map do |name|
      File.write(File.join(origin, "README"), "#{name}\n")
      git.call("add", "README")
      git.call("commit", "-qm", name)
      `git -C #{origin} rev-parse HEAD`.strip
    end
    git.call("tag", "-a", "-m", "v1.2.3", "v1.2.3", shas[0])
    system("git", "clone", "-q", origin, clone, exception: true, err: File::NULL)
    system("git", "tag", "-f", "-a", "-m", "v1.2.3", "v1.2.3", shas[1], chdir: origin, exception: true, out: File::NULL, err: File::NULL) if move
    system("git", "tag", "-d", "v1.2.3", chdir: origin, exception: true, out: File::NULL) if delete
    yield clone, *shas
  ensure
    FileUtils.rm_rf(root) if root
  end

  # Runs the stable-tag guard extracted from release.yml for `tag`.
  #
  # @param tag [String] the pushed tag name.
  # @return [Array(String, Process::Status)] stdout and exit status.
  def run_stable_tag_guard(tag)
    script = marked_block(STABLE_TAG_START, STABLE_TAG_END, workflow: RELEASE_WORKFLOW)
    out, _err, status = Open3.capture3({ "GITHUB_REF_NAME" => tag }, "bash", "-euo", "pipefail", "-c", script)
    [out, status]
  end

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

  # @return [String] the first workflow text between two marker comments, unindented.
  def marked_block(start_marker, end_marker, workflow: WORKFLOW)
    marked_blocks(start_marker, end_marker, workflow: workflow).first or
      raise "#{start_marker} / #{end_marker} missing from #{workflow}"
  end

  # @return [Array<String>] every workflow text between two marker comments, unindented.
  def marked_blocks(start_marker, end_marker, workflow: WORKFLOW)
    pattern = /#{Regexp.escape(start_marker)}.*?#{Regexp.escape(end_marker)}/m
    File.read(workflow).scan(pattern).map { |block| block.lines.map { |line| line.sub(/^          /, "") }.join }
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
