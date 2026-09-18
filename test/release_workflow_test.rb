# frozen_string_literal: true

require_relative "test_helper"
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

  def test_workflow_markers_wrap_the_live_calculation
    text = File.read(WORKFLOW)
    refute_nil text.index(CALC_START), "release-pr.yml needs #{CALC_START}"
    refute_nil text.index(CALC_END), "release-pr.yml needs #{CALC_END}"
    assert_includes version_calc_script, "git tag --list --sort=-v:refname"
    refute_match(/^latest_tag="\$\(git describe/, version_calc_script)
  end

  private

  # Extracts the marked calculation block from the workflow, dropping YAML indent.
  #
  # @return [String] bash script text.
  def version_calc_script
    text = File.read(WORKFLOW)
    start = text.index(CALC_START)
    finish = text.index(CALC_END)
    raise "version calc markers missing from #{WORKFLOW}" unless start && finish

    text[start..finish].lines.map { |line| line.sub(/^          /, "") }.join
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
    Dir.mktmpdir("mutineer-release-calc") do |dir|
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
    end
  end
end
