# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "json"

# Drives bin/mutineer as a real subprocess so flag parsing, validation exit codes,
# and --list-operators are exercised end to end.
class CliTest < Minitest::Test
  ROOT     = File.expand_path("..", __dir__)
  BIN      = File.join(ROOT, "bin", "mutineer")
  FIXTURES = File.expand_path("fixtures", __dir__)

  def mutineer(*args, chdir: Dir.tmpdir)
    Open3.capture3(RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}", BIN, *args, chdir: chdir)
  end

  # An isolated project dir with the calculator fixtures copied in, so the run is
  # real but the .mutineer cache lands in the temp dir, never the repo.
  def with_project
    Dir.mktmpdir("mutineer-proj") do |proj|
      %w[calculator.rb calculator_strong_test.rb calculator_weak_test.rb].each do |f|
        FileUtils.cp(File.join(FIXTURES, f), File.join(proj, f))
      end
      yield proj
    end
  end

  def test_list_operators_shows_default_and_disabled
    out, _, status = mutineer("--list-operators")
    assert_equal 0, status.exitstatus
    assert_match(/arithmetic\s+tier 1\s+default/, out)
    assert_match(/return_nil\s+tier 2\s+disabled/, out)
    assert_match(/literal_mutation\s+tier 2\s+disabled/, out)
    assert_match(/condition_negation\s+tier 2\s+disabled/, out)
  end

  # C7: every flag/usage failure exits 2 (usage), distinct from exit 1 (tests too
  # weak) and exit 0 (success).
  def test_jobs_zero_exits_two
    _, err, status = mutineer("run", "x.rb", "--jobs", "0")
    assert_equal 2, status.exitstatus
    assert_includes err, "--jobs requires a positive integer"
  end

  def test_unknown_format_exits_two
    _, err, status = mutineer("run", "x.rb", "--format", "csv")
    assert_equal 2, status.exitstatus
    assert_includes err, %(unknown format "csv")
  end

  def test_unknown_strategy_exits_two
    _, err, status = mutineer("run", "x.rb", "--strategy", "bogus")
    assert_equal 2, status.exitstatus
    assert_includes err, %(unknown strategy "bogus")
  end

  def test_unknown_framework_exits_two
    _, err, status = mutineer("run", "x.rb", "--framework", "junit")
    assert_equal 2, status.exitstatus
    assert_includes err, %(unknown framework "junit")
  end

  def test_unwritable_output_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--output", "/no-such-dir/out.json")
    assert_equal 2, status.exitstatus
    assert_includes err, "cannot write to"
  end

  # R5: a missing source/test path is a clean usage error, not an ENOENT backtrace.
  def test_missing_source_path_exits_two
    _, err, status = mutineer("run", "no_such_source.rb", "--test", "no_such_test.rb")
    assert_equal 2, status.exitstatus
    assert_includes err, "no such file"
    refute_includes err, "(Errno::ENOENT)"
  end

  # Boot mode does no coverage selection, so it requires at least one --test file.
  def test_boot_without_test_exits_two
    src = File.join(FIXTURES, "boot", "widget.rb")
    app = File.join(FIXTURES, "boot", "app_boot.rb")
    _, err, status = mutineer("run", src, "--boot", app)
    assert_equal 2, status.exitstatus
    assert_includes err, "--boot/--rails requires at least one --test file"
  end

  # --rails defaults boot to config/environment; with no --test the same usage
  # error fires first (deterministic, needs no real Rails app or DB).
  def test_rails_alone_demands_test_first
    src = File.join(FIXTURES, "boot", "widget.rb")
    _, err, status = mutineer("run", src, "--rails")
    assert_equal 2, status.exitstatus
    assert_includes err, "--boot/--rails requires at least one --test file"
  end

  # --since with a ref git cannot resolve is a usage error (exit 2). Run inside
  # the mutineer repo (chdir: ROOT) so git exists and we're in a work tree; the
  # ref name is one that cannot exist.
  def test_since_unknown_ref_exits_two
    _, err, status = mutineer("run", "lib/mutineer/version.rb",
                              "--since", "definitely-not-a-ref-xyz", chdir: ROOT)
    assert_equal 2, status.exitstatus
    assert_includes err, "unknown git ref: definitely-not-a-ref-xyz"
  end

  # --- happy paths driven through bin/mutineer -----------------------------

  def test_successful_run_exits_zero
    with_project do |proj|
      out, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_includes out, "Mutation score: 100.0%"
    end
  end

  def test_below_threshold_exits_one
    with_project do |proj|
      _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                              "--threshold", "90", chdir: proj)
      assert_equal 1, status.exitstatus
    end
  end

  def test_dry_run_prints_breakdown
    with_project do |proj|
      out, _, status = mutineer("run", "calculator.rb", "--dry-run", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_includes out, "mutations (dry run, not executed)"
      assert_includes out, "arithmetic:"
    end
  end

  def test_json_output_round_trips_to_file
    with_project do |proj|
      _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                              "--format", "json", "--output", "report.json", chdir: proj)
      assert_equal 0, status.exitstatus
      doc = JSON.parse(File.read(File.join(proj, "report.json")))
      assert_equal "1.0", doc["schema_version"]
      assert_equal 100.0, doc["summary"]["score"]
    end
  end

  def test_strategy_surgical_smoke
    with_project do |proj|
      _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                              "--strategy", "7b", chdir: proj)
      assert_equal 0, status.exitstatus
    end
  end

  # A syntactically invalid source is reported cleanly, not as a raw backtrace.
  def test_syntax_error_source_is_handled_cleanly
    with_project do |proj|
      File.write(File.join(proj, "broken.rb"), "def oops(\n")
      _, err, status = mutineer("run", "broken.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      refute_equal 0, status.exitstatus
      refute_includes err, "cli.rb:", "no internal backtrace should leak"
    end
  end

  # #14: tier-2 operators are surfaced when they're not in the active set.
  def test_tier2_hint_lists_unused_tier2_operators
    hint = Mutineer::CLI.tier2_hint(nil) # nil => default (Tier-1) set
    Mutineer::MutatorRegistry::TIER2_NAMES.each { |op| assert_includes hint, op }
    assert_includes hint, "--operators"
  end

  def test_tier2_hint_nil_when_all_enabled
    all = Mutineer::MutatorRegistry::DEFAULT_NAMES + Mutineer::MutatorRegistry::TIER2_NAMES
    assert_nil Mutineer::CLI.tier2_hint(all)
  end
end
