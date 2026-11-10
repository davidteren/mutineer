# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../rake/fizzy_sample"

# #402: the pre-release Fizzy check. These tests cover the comparison, the
# recording rules and the child process setup on parsed JSON, with no Fizzy
# clone, network or bundle.
class FizzySampleTest < Minitest::Test
  BASE = { "total" => 20, "killed" => 17, "survived" => 3, "errored" => 0, "no_verdict" => 0,
           "score" => 85.0, "scoped" => false,
           "declined_by_operator" => { "a" => 1, "b" => 0 }, "legacy_id_matches" => { "ignore" => 0 } }.freeze

  def report(summary = {}, survivors: %w[s1 s2], no_verdict: [])
    { "summary" => BASE.merge(summary), "survivors" => survivors.map { |id| { "id" => id } },
      "no_verdict" => no_verdict }
  end

  def data(rep = report)
    { "commit" => "abc", "files" => ["a.rb"], "counts" => FizzySample.counts(rep["summary"]),
      "survivors" => rep["survivors"].map { |s| s["id"] }.sort,
      "recorded" => { "mutineer_version" => "1.8.2", "mutineer_sha" => "sha" } }
  end

  def meta(sha = "head", commit: "abc", files: ["a.rb"])
    { "commit" => commit, "files" => files, "mutineer_sha" => sha, "app_ruby" => "3.4.8" }
  end

  def test_counts_skip_score_and_booleans_and_flatten_integer_hashes
    counts = FizzySample.counts(BASE)
    refute counts.key?("score")
    refute counts.key?("scoped")
    assert_equal 1, counts["declined_by_operator.a"]
    assert_equal 0, counts["legacy_id_matches.ignore"]
  end

  def test_equal_reports_match
    assert_equal [[], []], FizzySample.compare(data, report)
  end

  def test_changed_counts_name_old_and_new_values
    failures, = FizzySample.compare(data, report({ "errored" => 2, "killed" => 15, "no_verdict" => 2 }))
    assert_includes failures, "errored: 0 -> 2"
    assert_includes failures, "killed: 17 -> 15"
    assert_includes failures, "no_verdict: 0 -> 2"
    assert_equal 3, failures.size
  end

  def test_errored_fails_even_when_it_matches_the_stored_value
    rep = report({ "errored" => 1 })
    failures, = FizzySample.compare(data(rep), rep)
    assert_equal ["errored: 1 (must be 0)"], failures
  end

  def test_new_and_gone_survivors_name_the_ids
    failures, = FizzySample.compare(data, report(survivors: %w[s1 s3]))
    assert_includes failures, 'survivors new: ["s3"]'
    assert_includes failures, 'survivors gone: ["s2"]'
  end

  def test_a_new_report_key_is_a_note_not_a_failure
    failures, notes = FizzySample.compare(data, report({ "unpaired_sources" => 4 }))
    assert_empty failures
    assert_equal ["note: new report key unpaired_sources = 4 (not compared)"], notes
  end

  def test_a_stored_key_missing_from_the_report_fails
    rep = report
    rep["summary"] = rep["summary"].reject { |k, _| k == "killed" }
    failures, = FizzySample.compare(data, rep)
    assert_equal ["killed: missing from the report"], failures
  end

  def test_a_decline_moving_between_operators_names_both_keys
    failures, = FizzySample.compare(data, report({ "declined_by_operator" => { "a" => 0, "b" => 1 } }))
    assert_equal ["declined_by_operator.a: 1 -> 0", "declined_by_operator.b: 0 -> 1"], failures
  end

  def test_no_stored_counts_fails_and_names_record
    failures, = FizzySample.compare({ "commit" => "abc" }, report)
    assert_equal 1, failures.size
    assert_includes failures.first, "rake fizzy:record"
  end

  def test_no_verdict_lines
    rep = report(no_verdict: [{ "file" => "app/m.rb", "line" => 3, "status" => "error", "details" => "boom" }])
    assert_equal ["app/m.rb:3 error boom"], FizzySample.no_verdict_lines(rep)
  end

  def test_record_refuses_errored
    err = assert_raises(FizzySample::Error) { FizzySample.recorded(data, report({ "errored" => 2 }), meta, "head") }
    assert_includes err.message, "errored is 2"
  end

  def test_record_refuses_a_report_from_another_commit_and_names_both
    err = assert_raises(FizzySample::Error) { FizzySample.recorded(data, report, meta("old"), "head") }
    assert_includes err.message, "old"
    assert_includes err.message, "head"
    assert_raises(FizzySample::Error) { FizzySample.recorded(data, report, meta(commit: "zzz"), "head") }
    assert_raises(FizzySample::Error) { FizzySample.recorded(data, report, meta(files: ["b.rb"]), "head") }
  end

  def test_record_allows_timeouts_and_stores_sorted_ids_and_provenance
    out = FizzySample.recorded({ "commit" => "abc", "files" => ["a.rb"] },
                               report({ "timeout" => 3 }, survivors: %w[z a]), meta, "head")
    assert_equal 3, out["counts"]["timeout"]
    assert_equal %w[a z], out["survivors"]
    assert_equal Mutineer::VERSION, out["recorded"]["mutineer_version"]
    assert_equal "head", out["recorded"]["mutineer_sha"]
    assert_equal "3.4.8", out["recorded"]["app_ruby"]
    assert_match(/\A\d{4}-\d\d-\d\d\z/, out["recorded"]["date"])
  end

  def test_completed_needs_exit_0_or_1_and_a_report
    Dir.mktmpdir do |dir|
      path = File.join(dir, "report.json")
      refute FizzySample.completed?(0, path)
      File.write(path, "{}")
      assert FizzySample.completed?(0, path)
      assert FizzySample.completed?(1, path)
      refute FizzySample.completed?(2, path)
      refute FizzySample.completed?(nil, path)
    end
  end

  def test_cache_dir_follows_xdg_cache_home
    assert_equal "/x/mutineer/fizzy-sample", FizzySample.cache_dir("XDG_CACHE_HOME" => "/x")
    assert_equal File.join(Dir.home, ".cache/mutineer/fizzy-sample"), FizzySample.cache_dir({})
  end

  def test_run_command_uses_this_checkout_and_absolute_ruby
    cmd = FizzySample.run_command(["a.rb"], "/c/report.json")
    assert_equal RbConfig.ruby, cmd[0]
    assert_equal File.expand_path("../bin/mutineer", __dir__), cmd[1]
    assert_equal ["run", "a.rb", "--daemon", "--jobs", "4", "--format", "json", "--output", "/c/report.json"], cmd[2..]
  end

  def test_child_env_pins_ruby_and_drops_rbenv_version_bins
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "shims"))
      bin = File.join(root, "versions", "3.4.9", "bin")
      FileUtils.mkdir_p(bin)
      env = FizzySample.child_env("3.4.8", { "RBENV_ROOT" => root, "PATH" => "#{bin}:/usr/bin",
                                             "CI" => "true", "SEED" => "4", "HOME" => root })
      assert_equal "3.4.8", env["RBENV_VERSION"]
      assert_equal "3.4.8", env["ASDF_RUBY_VERSION"]
      assert_equal "test", env["RAILS_ENV"]
      assert_equal "false", env["SAAS"]
      assert_equal "sqlite", env["DATABASE_ADAPTER"]
      refute env.key?("CI")
      refute env.key?("SEED")
      assert_equal [File.join(root, "shims"), "/usr/bin"], env["PATH"].split(":")
    end
  end

  def test_verify_ruby_names_both_versions
    err = assert_raises(FizzySample::Error) { FizzySample.verify_ruby!("3.4.8", "3.4.9") }
    assert_includes err.message, "3.4.8"
    assert_includes err.message, "3.4.9"
    FizzySample.verify_ruby!("3.4.8", "3.4.8")
  end

  def test_config_has_no_require_key
    assert_equal({ "rails" => true, "daemon" => true, "shared_databases" => ["cable"] }, FizzySample::CONFIG)
  end

  def test_a_second_run_on_the_same_cache_fails_at_once
    Dir.mktmpdir do |cache|
      FizzySample.with_lock(cache) do
        err = assert_raises(FizzySample::Error) { FizzySample.with_lock(cache) { flunk "ran inside a held lock" } }
        assert_includes err.message, cache
      end
    end
  end

  def test_stored_pin_has_a_full_commit_and_files
    stored = JSON.parse(File.read(FizzySample::DATA))
    assert_match(/\A\h{40}\z/, stored["commit"])
    refute_empty stored["files"]
  end
end
