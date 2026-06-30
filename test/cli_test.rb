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
      assert_equal "1.1", doc["schema_version"]
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

  # #8: --verbose is documented and both it and its --debug alias are accepted
  # flags (not "invalid option") — a clean run still exits 0.
  def test_help_documents_verbose
    out, _, status = mutineer("--help")
    assert_equal 0, status.exitstatus
    assert_includes out, "--verbose"
  end

  def test_verbose_and_debug_are_accepted_flags
    with_project do |proj|
      %w[--verbose --debug].each do |flag|
        _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  flag, chdir: proj)
        assert_equal 0, status.exitstatus, "#{flag} should be accepted"
        refute_includes err, "invalid option"
      end
    end
  end

  # #22: --dry-run honors suppression — a `# mutineer:disable-line` mutation is
  # omitted from the listing and counted as "ignored (suppressed)".
  def test_dry_run_honors_suppression
    out, _, status = mutineer("run", File.join(FIXTURES, "equivalent.rb"), "--dry-run", chdir: ROOT)
    assert_equal 0, status.exitstatus
    assert_match(/ignored \(suppressed\)/, out)
    refute_match(/Equivalent#add/, out, "the disable-line'd add mutation must not be listed")
    assert_match(/Equivalent#double/, out, "the non-suppressed mutation is still listed")
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

  # --- #11 auto-pairing (driven through bin/mutineer) ----------------------

  # Copy the conventional autopair fixture tree (lib/ + test/) into a temp dir.
  def with_autopair_project
    Dir.mktmpdir("mutineer-autopair") do |proj|
      FileUtils.cp_r(File.join(FIXTURES, "autopair", "."), proj)
      yield proj
    end
  end

  # R1/R2/R7: a directory source expands and each file is paired to its test by
  # convention; the combined JSON carries a per_source entry per source.
  def test_directory_autopair_produces_per_source
    with_autopair_project do |proj|
      out, _, status = mutineer("run", "lib", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus
      doc = JSON.parse(out)
      assert_equal "1.1", doc["schema_version"]
      per = doc["per_source"].sort_by { |h| h["file"] }
      assert_equal ["lib/calc.rb", "lib/greeter.rb"], per.map { |h| h["file"] }
      assert_equal 100.0, per.find { |h| h["file"] == "lib/greeter.rb" }["score"]
      assert_operator per.find { |h| h["file"] == "lib/calc.rb" }["score"], :<, 100.0
    end
  end

  # R3: a source with no inferred test warns on stderr and is skipped; the run
  # continues on the rest (not exit 2).
  def test_orphan_source_warns_and_is_skipped
    with_autopair_project do |proj|
      File.write(File.join(proj, "lib", "orphan.rb"), "class Orphan; def z(a); a + 1; end; end\n")
      out, err, status = mutineer("run", "lib", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_includes err, "[mutineer] no test found by convention for lib/orphan.rb; skipping"
      files = JSON.parse(out)["per_source"].map { |h| h["file"] }
      refute_includes files, "lib/orphan.rb"
    end
  end

  # R3: when EVERY source lacks a test, it's a usage error (exit 2), not a crash.
  def test_all_sources_unpaired_exits_two
    Dir.mktmpdir("mutineer-notests") do |proj|
      FileUtils.mkdir_p(File.join(proj, "lib"))
      File.write(File.join(proj, "lib", "a.rb"), "class A; def z(a); a + 1; end; end\n")
      _, err, status = mutineer("run", "lib", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "no test files found by convention"
    end
  end

  # R5: an explicit --test disables inference entirely — only the named source runs.
  def test_explicit_test_overrides_autopairing
    with_autopair_project do |proj|
      out, err, status = mutineer("run", "lib/calc.rb", "--test", "test/calc_test.rb",
                                  "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus
      refute_includes err, "no test found by convention"
      files = JSON.parse(out)["per_source"].map { |h| h["file"] }
      assert_equal ["lib/calc.rb"], files
    end
  end

  # --- #13 baseline gating, end to end through bin/mutineer -----------------

  # A bad/missing baseline path is a usage error (exit 2), like every other path.
  def test_bad_baseline_path_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--baseline", "/no/such.json")
    assert_equal 2, status.exitstatus
    assert_includes err, "mutineer:"
  end

  # NEW survivors vs a clean (100%) baseline regress -> exit 1, named on stdout.
  def test_baseline_new_survivors_exit_one
    with_project do |proj|
      _, _, s1 = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                          "--format", "json", "--output", "base.json", chdir: proj)
      assert_equal 0, s1.exitstatus
      out, _, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                                "--baseline", "base.json", chdir: proj)
      assert_equal 1, status.exitstatus
      assert_includes out, "new survivors vs baseline"
      assert_includes out, "REGRESSION vs baseline"
    end
  end

  # Re-running the same (weak) run against its own baseline introduces nothing new
  # -> exit 0; ids are content-based so they match across runs.
  def test_baseline_no_regression_exits_zero
    with_project do |proj|
      _, _, s1 = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                          "--format", "json", "--output", "base.json", chdir: proj)
      assert_equal 0, s1.exitstatus
      out, _, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                                "--baseline", "base.json", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_includes out, "0 new survivors vs baseline"
      assert_includes out, "OK: no regression vs baseline"
    end
  end
end
