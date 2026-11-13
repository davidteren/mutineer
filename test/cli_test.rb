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

  def mutineer(*args, chdir: Dir.tmpdir, env: {})
    Open3.capture3(env, RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}", BIN, *args, chdir: chdir)
  end

  # An isolated project dir with the calculator fixtures copied in, so the run is
  # real but the .mutineer cache lands in the temp dir, never the repo.
  # The [mutineer] old-format ignore warnings in a stderr capture.
  # The unmatched-entry warning starts the same way and is not one of these.
  def legacy_warnings(err)
    err.lines.grep(/\A\[mutineer\] ignore entry .* old id format/)
  end

  # The [mutineer] warning for an ignore entry that matched no mutant (#377).
  def unmatched_warnings(err)
    err.lines.grep(/\A\[mutineer\] ignore entry .* matched no mutant/)
  end

  # The [mutineer] run-root mismatch warning in a stderr capture.
  def root_warnings(err)
    err.lines.grep(/\A\[mutineer\] loaded .*\.mutineer\.yml/)
  end

  # Ids are relative to the run directory (#126). A run from a subdirectory
  # still finds the parent's .mutineer.yml by walking up, so its ignore ids
  # would silently stop matching; the CLI must say so once.
  def test_run_from_a_subdirectory_of_the_config_warns_once
    Dir.mktmpdir("mutineer-root") do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "threshold: 0\n")
      sub = File.join(proj, "sub")
      FileUtils.mkdir_p(sub)
      _out, err, = mutineer("run", "--dry-run", "nothing.rb", chdir: sub)
      assert_equal 1, root_warnings(err).size, "expected one run-root warning, got: #{err}"
      assert_includes err, File.realpath(proj)
    end
  end

  # A ~/.mutineer.yml is a personal default, not a project root: running from
  # any project below home must not warn to "run from home".
  def test_home_level_config_does_not_warn
    Dir.mktmpdir("mutineer-home") do |home|
      File.write(File.join(home, ".mutineer.yml"), "threshold: 0\n")
      proj = File.join(home, "proj")
      FileUtils.mkdir_p(proj)
      _out, err, = Open3.capture3({ "HOME" => home }, RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}", BIN,
                                  "run", "--dry-run", "nothing.rb", chdir: proj)
      assert_empty root_warnings(err), "a home-level config must not warn, got: #{err}"
    end
  end

  def test_run_from_the_config_directory_does_not_warn
    Dir.mktmpdir("mutineer-root") do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "threshold: 0\n")
      _out, err, = mutineer("run", "--dry-run", "nothing.rb", chdir: proj)
      assert_empty root_warnings(err), "no run-root warning expected, got: #{err}"
    end
  end

  # [old-format id, new id] of the first arithmetic mutant in proj/calculator.rb.
  def calculator_ids(proj)
    path = File.join(proj, "calculator.rb")
    source = File.read(path)
    subject = Mutineer::Project.discover([path]).find { |s| Mutineer::Mutators::Arithmetic.new.mutations_for(s, source).any? }
    mutation = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first
    [Mutineer::MutantId.legacy_for(subject, mutation, source),
     Mutineer::MutantId.for(subject, mutation, source, path: "calculator.rb")]
  end

  # [old id, new id] for the first arithmetic mutant of each calculator method.
  def arithmetic_id_pairs(proj)
    path = File.join(proj, "calculator.rb")
    source = File.read(path)
    Mutineer::Project.discover([path]).filter_map do |subject|
      mutation = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first
      next unless mutation

      [Mutineer::MutantId.legacy_for(subject, mutation, source),
       Mutineer::MutantId.for(subject, mutation, source, path: "calculator.rb")]
    end
  end

  def with_project
    Dir.mktmpdir("mutineer-proj") do |proj|
      %w[calculator.rb calculator_strong_test.rb calculator_weak_test.rb].each do |f|
        FileUtils.cp(File.join(FIXTURES, f), File.join(proj, f))
      end
      yield proj
    end
  end

  # #303: with LC_ALL=C Ruby reads files as US-ASCII. A source line with a
  # non-ASCII character must still run, report, and gate on a baseline.
  def test_non_ascii_source_runs_and_gates_under_an_ascii_locale
    with_project do |proj|
      path = File.join(proj, "calculator.rb")
      File.write(path, File.read(path).sub("    a + b\n", "    a + b # caf\u00e9\n"))
      env = { "LC_ALL" => "C", "LANG" => nil }
      run = ["run", "calculator.rb", "--test", "calculator_weak_test.rb", "--operators", "arithmetic", "--jobs", "1"]
      ruby = [RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}", BIN]

      # binmode: this test process may run under an ASCII locale too.
      out, err, status = Open3.capture3(env, *ruby, *run, "--format", "json", chdir: proj, binmode: true)
      assert_equal 0, status.exitstatus, err
      File.write(File.join(proj, "base.json"), out)
      assert_includes JSON.parse(out)["survivors"].map { |s| s["diff"] }.join, "caf\u00e9"

      _, err, status = Open3.capture3(env, *ruby, *run, "--baseline", "base.json", chdir: proj)
      assert_equal 0, status.exitstatus, err
    end
  end

  def test_triage_without_a_reason_is_usage_not_an_unknown_command
    _, err, status = mutineer("triage", "report.json", "--all")
    assert_equal 2, status.exitstatus
    assert_includes err, "--reason"
    refute_includes err, "unknown command"
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
    assert_includes err, "--jobs must be a positive integer, digits only"
  end

  # #105: a fractional or non-integer --jobs is a usage error, never rounded down.
  def test_fractional_jobs_exits_two
    _, err, status = mutineer("run", "x.rb", "--jobs", "1.9")
    assert_equal 2, status.exitstatus
    assert_includes err, %(--jobs must be a positive integer, digits only (got: "1.9"))
  end

  # #105: the same rule applies to a .mutineer.yml `jobs:` key, with the file named.
  def test_config_file_bad_jobs_exits_two_without_backtrace
    ["1.9", "true", "0"].each do |bad|
      with_project do |proj|
        File.write(File.join(proj, ".mutineer.yml"), "jobs: #{bad}\n")
        _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)
        assert_equal 2, status.exitstatus, "jobs: #{bad}"
        assert_includes err, ".mutineer.yml: jobs must be a positive integer, digits only"
        refute_match(/\.rb:\d+:in /, err, "no backtrace for jobs: #{bad}")
      end
    end
  end

  def test_cache_dir_holds_the_coverage_cache
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--cache-dir", "tmp/run-a", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_path_exists File.join(proj, "tmp/run-a/coverage.json")
      refute_path_exists File.join(proj, ".mutineer")
    end
  end

  def shared_capture_run(proj, *args)
    mutineer("run", *args, "--test", "alpha_test.rb", "--test", "beta_test.rb", "--strategy", "redefine",
             "--jobs", "1", "--format", "json", chdir: proj)
  end

  def with_shared_capture_project
    Dir.mktmpdir("mutineer-proj") do |proj|
      FileUtils.cp(Dir[File.join(FIXTURES, "shared_capture", "*.rb")], proj)
      yield proj
    end
  end

  def test_coverage_from_gives_the_verdicts_of_a_fresh_run
    with_shared_capture_project do |proj|
      _, err, status = shared_capture_run(proj, "alpha.rb", "beta.rb", "--boot", "boot.rb", "--cache-dir", "capture")
      assert_equal 0, status.exitstatus, err
      reused, err, status = shared_capture_run(proj, "alpha.rb", "--boot", "boot.rb", "--cache-dir", "shard",
                                               "--coverage-from", "capture/coverage.json")
      assert_equal 0, status.exitstatus, err
      fresh, = shared_capture_run(proj, "alpha.rb", "--boot", "boot.rb", "--cache-dir", "fresh")
      assert_equal JSON.parse(fresh), JSON.parse(reused)
      # The flag is read, not ignored: a capture that is no cache stops the run.
      File.write(File.join(proj, "capture", "coverage.json"), "{}")
      _, err, status = shared_capture_run(proj, "alpha.rb", "--boot", "boot.rb", "--cache-dir", "shard2",
                                          "--coverage-from", "capture/coverage.json")
      assert_equal 2, status.exitstatus, err
      assert_match(/is not a coverage cache/, err)
    end
  end

  def test_coverage_from_rejects_a_lazy_capture_whose_other_sources_ran_these_at_load
    with_shared_capture_project do |proj|
      shared_capture_run(proj, "alpha.rb", "beta.rb", "--boot", "lazy_boot.rb", "--cache-dir", "capture")
      _, err, status = shared_capture_run(proj, "alpha.rb", "--boot", "lazy_boot.rb", "--cache-dir", "shard",
                                          "--coverage-from", "capture/coverage.json")
      assert_equal 2, status.exitstatus, err
      assert_match(/lines of alpha\.rb ran at load in only one of the capture and this run.*eager-load/, err)
      refute_match(/\.rb:\d+:in /, err)
    end
  end

  def test_coverage_from_warns_that_it_has_no_effect_without_boot
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--coverage-from", "elsewhere/coverage.json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "[mutineer] --coverage-from has no effect with a run without --rails/--boot"
    end
  end

  def test_a_test_file_given_as_a_source_after_test_exits_two
    with_project do |proj|
      FileUtils.mkdir_p(File.join(proj, "test"))
      %w[calculator_strong_test.rb calculator_weak_test.rb].each do |f|
        FileUtils.mv(File.join(proj, f), File.join(proj, "test", f))
      end
      _, err, status = mutineer("run", "calculator.rb", "--test", "test/calculator_strong_test.rb",
                                "test/calculator_weak_test.rb", chdir: proj)
      assert_equal 2, status.exitstatus, err
      assert_includes err, "test/calculator_weak_test.rb looks like a test file, not a source"
      assert_includes err, "Quote the glob"
    end
  end

  def test_a_test_prefixed_file_given_as_a_source_after_test_exits_two
    with_project do |proj|
      FileUtils.mkdir_p(File.join(proj, "test"))
      %w[test_a.rb test_b.rb].each { |f| FileUtils.touch(File.join(proj, "test", f)) }
      _, err, status = mutineer("run", "--dry-run", "calculator.rb", "--test", "test/test_a.rb",
                                "test/test_b.rb", chdir: proj)
      assert_equal 2, status.exitstatus, err
      assert_includes err, "test/test_b.rb looks like a test file, not a source"
    end
  end

  def test_a_root_level_test_file_given_as_a_source_after_test_exits_two
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "calculator_weak_test.rb", chdir: proj)
      assert_equal 2, status.exitstatus, err
      assert_includes err, "calculator_weak_test.rb looks like a test file, not a source"
    end
  end

  def test_a_stray_test_file_with_json_format_exits_two_before_any_output
    with_project do |proj|
      out, err, status = mutineer("run", "--format", "json", "calculator.rb", "--test",
                                  "calculator_strong_test.rb", "calculator_weak_test.rb", chdir: proj)
      assert_equal 2, status.exitstatus, err
      assert_empty out
    end
  end

  def test_a_root_level_source_named_like_a_test_still_runs
    Dir.mktmpdir("mutineer-ab") do |proj|
      File.write(File.join(proj, "ab_test.rb"), "class AbTest\n  def n = 1 + 1\nend\n")
      File.write(File.join(proj, "ab_test_test.rb"), "")
      out, err, status = mutineer("run", "--dry-run", "ab_test.rb", "--test", "ab_test_test.rb", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "AbTest#n"
    end
  end

  def test_a_source_named_like_a_test_outside_test_dirs_still_runs
    Dir.mktmpdir("mutineer-ab") do |proj|
      FileUtils.mkdir_p(File.join(proj, "app/models"))
      FileUtils.mkdir_p(File.join(proj, "test/models"))
      File.write(File.join(proj, "app/models/ab_test.rb"), "class AbTest\n  def n = 1 + 1\nend\n")
      File.write(File.join(proj, "test/models/ab_test_test.rb"), "")
      out, err, status = mutineer("run", "--dry-run", "app/models/ab_test.rb",
                                  "--test", "test/models/ab_test_test.rb", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "AbTest#n"
    end
  end

  def test_config_file_integer_jobs_runs
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "jobs: 2\n")
      _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 0, status.exitstatus
    end
  end

  # #105: a bad --baseline-epsilon fails at parse time, before any test runs.
  def test_bad_baseline_epsilon_exits_two_before_running
    ["abc", "-1", "NaN", "Infinity"].each do |bad|
      with_project do |proj|
        _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  "--baseline-epsilon", bad, chdir: proj)
        assert_equal 2, status.exitstatus, bad
        assert_includes err, "--baseline-epsilon must be a finite number, 0 or greater"
        refute_includes err, "[mutineer] 1/", "tests ran for #{bad}"
      end
    end
  end

  def test_valid_baseline_epsilon_runs
    %w[0 0.5].each do |ok|
      with_project do |proj|
        _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--baseline-epsilon", ok, chdir: proj)
        assert_equal 0, status.exitstatus, ok
      end
    end
  end

  def test_non_numeric_threshold_exits_two
    _, err, status = mutineer("run", "x.rb", "--threshold", "abc")
    assert_equal 2, status.exitstatus
    assert_includes err, "--threshold must be a number between 0 and 100"
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

  # #270: the documented --output .mutineer/run.json works on a fresh checkout.
  # The cache dir is the one missing parent the preflight creates.
  def test_output_in_missing_cache_dir_is_created
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--format", "json", "--output", ".mutineer/run.json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert File.file?(File.join(proj, ".mutineer", "run.json"))
    end
  end

  # A dry run writes no report, so it does not create the cache dir.
  def test_dry_run_output_in_missing_cache_dir_creates_nothing
    with_project do |proj|
      _, err, status = mutineer("run", "--dry-run", "calculator.rb", "--output", ".mutineer/run.json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      refute File.exist?(File.join(proj, ".mutineer"))
    end
  end

  # #270: only the cache dir itself is created. A missing child of it, or any
  # other missing relative parent, is still a usage error.
  def test_output_in_other_missing_dir_exits_two
    with_project do |proj|
      %w[reports/run.json .mutineer/sub/run.json].each do |output|
        _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  "--output", output, chdir: proj)
        assert_equal 2, status.exitstatus, output
        assert_includes err, "no such directory"
      end
    end
  end

  # #270: the created dir is the configured cache dir, not a literal `.mutineer`.
  def test_output_in_missing_custom_cache_dir_is_created
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--cache-dir", "mcache",
                                "--format", "json", "--output", "mcache/run.json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert File.file?(File.join(proj, "mcache", "run.json"))

      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--cache-dir", "mcache",
                                "--output", ".mutineer/run.json", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "no such directory"
    end
  end

  # #270: a cache dir that cannot be created is a usage error before the run.
  def test_output_in_uncreatable_cache_dir_exits_two
    with_project do |proj|
      File.write(File.join(proj, "blocker"), "")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--cache-dir", "blocker/cache",
                                "--output", "blocker/cache/run.json", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "cannot write to blocker/cache/run.json"
      refute_includes err, "no such directory", "the mkdir_p failure must be reported, not the fallback check"
    end
  end

  # #27: --test-command usage errors — all exit 2 (usage), never a backtrace.
  def test_test_command_empty_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--test-command", "   ")
    assert_equal 2, status.exitstatus
    assert_includes err, "--test-command must not be empty"
  end

  def test_test_command_without_files_placeholder_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--test-command", "bundle exec rails test")
    assert_equal 2, status.exitstatus
    assert_includes err, "must contain %{files}"
  end

  def test_test_command_with_redefine_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb",
                              "--test-command", "rake test %{files}", "--strategy", "redefine")
    assert_equal 2, status.exitstatus
    assert_includes err, "supports only --strategy reload"
  end

  def test_test_command_with_boot_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb",
                              "--test-command", "rake test %{files}", "--boot", "config/environment")
    assert_equal 2, status.exitstatus
    assert_includes err, "cannot be combined with --boot/--rails"
  end

  # --matrix runs in-process and needs every covering test, so each conflict is
  # a usage error named before any other check runs.
  def test_matrix_with_daemon_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--matrix", "--daemon", "--rails")
    assert_equal 2, status.exitstatus
    assert_includes err, "--matrix cannot be combined with --daemon"
  end

  def test_matrix_with_test_command_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--matrix", "--test-command", "rake test %{files}")
    assert_equal 2, status.exitstatus
    assert_includes err, "--matrix cannot be combined with --test-command"
    refute_includes err, "forcing --jobs 1"
  end

  # #407 OCR: matrix conflicts beat early shape/expansion checks that now run
  # before validate!, so the user still sees the --no-matrix hint first.
  def test_matrix_beats_test_command_shape_error
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--matrix", "--test-command", "rake test")
    assert_equal 2, status.exitstatus
    assert_includes err, "--matrix cannot be combined with --test-command"
    refute_includes err, "%{files}"
  end

  def test_matrix_beats_unmatched_test_glob
    _, err, status = mutineer("run", "x.rb", "--matrix", "--daemon", "--test", "nowhere/*")
    assert_equal 2, status.exitstatus
    assert_includes err, "--matrix cannot be combined with --daemon"
    refute_includes err, "matched no test files"
  end

  def test_matrix_with_fail_fast_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--matrix", "--fail-fast")
    assert_equal 2, status.exitstatus
    assert_includes err, "--matrix cannot be combined with --fail-fast"
  end

  # #191 review: a dry run runs no tests, so --matrix with it is a usage error,
  # not a silently dropped request.
  def test_matrix_with_dry_run_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--matrix", "--dry-run")
    assert_equal 2, status.exitstatus
    assert_includes err, "--matrix cannot be combined with --dry-run"
  end

  # #191 review: a typed --no-matrix / --no-fail-fast beats the file key, so a
  # file that sets one can still run with a flag that conflicts with it.
  def test_no_matrix_and_no_fail_fast_beat_the_config_file
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "matrix: true\n")
      args = ["run", "calculator.rb", "--test", "calculator_weak_test.rb"]
      _, err, status = mutineer(*args, "--dry-run", chdir: proj)
      assert_equal 2, status.exitstatus, "without --no-matrix the file's matrix: applies"
      assert_includes err, "matrix in .mutineer.yml cannot be combined with --dry-run"
      assert_includes err, "pass --no-matrix to run without it"
      _, err, status = mutineer(*args, "--dry-run", "--no-matrix", chdir: proj)
      assert_equal 0, status.exitstatus, err

      File.write(File.join(proj, ".mutineer.yml"), "fail_fast: true\n")
      _, err, status = mutineer(*args, "--matrix", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "--matrix cannot be combined with fail_fast in .mutineer.yml"
      assert_includes err, "pass --no-fail-fast to run without it"
      _, err, status = mutineer(*args, "--matrix", "--no-fail-fast", "--format", "json", chdir: proj)
      refute_includes err, "cannot be combined"
      assert_includes [0, 1], status.exitstatus, err
    end
  end

  def test_matrix_from_the_config_file_is_checked_too
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "matrix: true\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb", "--fail-fast", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "matrix in .mutineer.yml cannot be combined with --fail-fast"
    end
  end

  def test_matrix_names_a_conflict_set_in_the_config_file
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "fail_fast: true\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb", "--matrix", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "--matrix cannot be combined with fail_fast in .mutineer.yml"
    end
  end

  def test_matrix_adds_the_json_block_and_keeps_the_exit_code
    with_project do |proj|
      args = ["run", "calculator.rb", "--test", "calculator_weak_test.rb", "--operators", "arithmetic",
              "--format", "json", "--threshold", "50"]
      plain_out, _, plain_status = mutineer(*args, chdir: proj)
      out, _, status = mutineer(*args, "--matrix", chdir: proj)

      assert_equal plain_status.exitstatus, status.exitstatus
      plain = JSON.parse(plain_out)
      doc = JSON.parse(out)
      refute plain.key?("matrix")
      assert_equal plain["summary"], doc["summary"]
      assert_equal(%w[test_add test_subtract].map do |m|
        { "file" => "calculator_weak_test.rb", "name" => "CalculatorWeakTest##{m}", "id" => "CalculatorWeakTest##{m}" }
      end, doc.dig("matrix", "blind"))
      assert_equal 6, doc.dig("matrix", "mutants").size
    end
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

  # An empty --since is an error, not "no scoping": `--since "$REF"` with an
  # unset variable must not turn into a full run.
  def test_since_empty_ref_exits_two
    ["", "  "].each do |blank|
      _, err, status = mutineer("run", "lib/mutineer/version.rb", "--since", blank, chdir: ROOT)
      assert_equal 2, status.exitstatus
      assert_includes err, "--since must be a git ref, not blank (got: #{blank.inspect})"
    end
  end

  # The file path follows the same rule as the flag, and `since: false` stays
  # the one way to write "no scoping" in the file.
  def test_blank_since_in_config_file_exits_two_and_false_does_not
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "since: \"\"\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, ".mutineer.yml: since must be a git ref, not blank (got: \"\")"
      File.write(File.join(proj, ".mutineer.yml"), "since: false\n")
      _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 0, status.exitstatus
    end
  end

  # `only: false` in the file must fail like a bad flag. It once ran zero mutants,
  # scored nil and exited 0 even with a weak test.
  def test_only_false_in_config_file_exits_two
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "only: false\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, ".mutineer.yml: only must be a string (got: false)"
    end
  end

  # `baseline:` with no value once switched the baseline check off and exited 0.
  def test_string_key_with_no_value_in_config_file_exits_two
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "baseline:\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, ".mutineer.yml: baseline must be a string (got: nil)"
    end
  end

  # --no-daemon is accepted in 1.x (it changes nothing yet) so a user can pin
  # the serial --rails path before 2.0 makes the daemon the default.
  def test_no_daemon_flag_is_accepted
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--dry-run", "--no-daemon", chdir: proj)
      assert_equal 0, status.exitstatus, err
    end
  end

  # Like --no-fail-fast, a typed --no-daemon beats the file key: without it the
  # file's daemon: true reaches the daemon checks, which need --rails/--boot.
  def test_no_daemon_flag_beats_a_daemon_true_file_key
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "daemon: true\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 2, status.exitstatus, err
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--no-daemon", chdir: proj)
      assert_equal 0, status.exitstatus, err
    end
  end

  def test_misspelled_operators_flag_exits_two_with_a_hint
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--dry-run", "--operators", "comparsion", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, 'Unknown operator: "comparsion" (did you mean "comparison"?)'
    end
  end

  # `operators:` with no value still exits 2. --operators replaces that
  # list, including one that names only an unknown operator.
  def test_operators_flag_replaces_a_blank_or_unknown_file_list
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "operators:\n")
      _, err, status = mutineer("run", "calculator.rb", "--dry-run", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "operators must name at least one operator, not blank"

      out, err, status = mutineer("run", "calculator.rb", "--dry-run", "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_match(/arithmetic: [1-9]/, out)

      File.write(File.join(proj, ".mutineer.yml"), "operators: [bogus]\n")
      out, err, status = mutineer("run", "calculator.rb", "--dry-run", "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "unknown operator"
      assert_match(/arithmetic: [1-9]/, out)
    end
  end

  # --- happy paths driven through bin/mutineer -----------------------------

  def test_successful_run_exits_zero
    with_project do |proj|
      out, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_includes out, "Mutation score: 100.0%"
    end
  end

  # #96: a red unmutated suite must not certify a 100% mutation gate.
  def test_failing_clean_suite_exits_one_not_perfect_score
    with_project do |proj|
      File.write(File.join(proj, "calculator_strong_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "calculator"
        class CalculatorStrongTest < Minitest::Test
          def test_add
            refute_nil Calculator.new.add(2, 3)
          end
          def test_unrelated
            assert_equal 1, 2
          end
        end
      RUBY
      out, err, status = mutineer(
        "run", "calculator.rb", "--test", "calculator_strong_test.rb",
        "--operators", "arithmetic", "--jobs", "1", "--format", "json",
        "--threshold", "100", chdir: proj
      )
      assert_equal 1, status.exitstatus
      assert_match(/unmutated suite is not green/, err)
      assert_match(/CalculatorStrongTest#test_unrelated/, err)
      refute_match(/"score": 100\.0/, out)
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
      assert_includes out, "0 declined"
      mutations = out[/(\d+) mutations \(dry run/, 1]
      unpaired = out[/(\d+) unpaired \(1 source has no paired test/, 1]
      assert_equal mutations, unpaired
      assert_includes out, "no mutants in 0 of 6 methods"
    end
  end

  # #386: the Fizzy method shape (a bare if/else with a def-level rescue),
  # which the default operators do not mutate, beside `total`, which they do.
  DAY_SOURCE = "class Day\n  def day\n    if @day\n      Time.parse(@day)\n    else\n      Time.now\n    end\n  " \
               "rescue ArgumentError\n    :not_found\n  end\n\n  def total(a, b)\n    a + b\n  end\nend\n"

  def test_dry_run_counts_methods_with_no_mutants
    with_project do |proj|
      File.write(File.join(proj, "day.rb"), DAY_SOURCE)
      out, err, status = mutineer("run", "day.rb", "--dry-run", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "no mutants in 1 of 2 methods"
      refute_includes out, "no mutants: "

      out, err, status = mutineer("run", "day.rb", "--dry-run", "--verbose", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "no mutants: Day#day  day.rb:2\n"
      assert_includes out, "[arithmetic] Day#total"
    end
  end

  def test_dry_run_with_condition_false_mutates_the_bare_if
    with_project do |proj|
      File.write(File.join(proj, "day.rb"), DAY_SOURCE)
      out, err, status = mutineer("run", "day.rb", "--dry-run", "--verbose", "--operators", "condition_false", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal 1, out.scan("[condition_false] Day#day").size
      refute_includes out, "no mutants: Day#day"
      assert_includes out, "no mutants: Day#total  day.rb:12\n"
    end
  end

  def test_dry_run_labels_unmutated_methods_under_since
    with_project do |proj|
      File.write(File.join(proj, "day.rb"), DAY_SOURCE)
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      path = File.join(proj, "calculator.rb")
      File.write(path, File.read(path).sub("a + b", "a + b + 0"))
      out, err, status = mutineer("run", "calculator.rb", "day.rb", "--dry-run", "--since", "HEAD", chdir: proj)
      assert_equal 0, status.exitstatus, err
      # #420: only methods whose def intersects the calculator.rb edit.
      assert_match(/no mutants in 0 of 1 methods\n/, out)
      refute_match(/no mutants in .*not narrowed by --since/, out)
    end
  end

  def test_empty_run_names_unmutated_methods
    with_project do |proj|
      File.write(File.join(proj, "day.rb"), DAY_SOURCE.sub(/\n  def total.*?end\n/m, ""))
      _, err, status = mutineer("run", "day.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "1 method was found, and the selected operators made no mutant in it " \
                           "(--list-operators shows the others)."
      refute_includes err, "Check that the sources contain code"

      File.write(File.join(proj, "day.rb"), DAY_SOURCE.sub(/  def total.*?end\n/m, "  def noop; end\n"))
      _, err, status = mutineer("run", "day.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "2 methods were found, and the selected operators made no mutant in any of them"
    end
  end

  def test_json_report_carries_unmutated_subjects
    with_project do |proj|
      path = File.join(proj, "calculator.rb")
      File.write(path, File.read(path).sub(/end\s*\z/, "  def note\n    if @n\n      :a\n    else\n      :b\n    end\n  end\nend\n"))
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--format", "json",
                                "--output", "r.json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(File.read(File.join(proj, "r.json")))
      assert_equal 7, doc["summary"]["subjects"]
      assert_equal 1, doc["summary"]["unmutated_subjects"]
      assert_equal ["Calculator#note"], doc["unmutated_subjects"].map { |h| h["subject"] }
    end
  end

  # #362: --dry-run --format json prints candidates with stable ids so a later
  # real run can be joined without parsing human text.
  def test_dry_run_format_json_lists_mutants_with_ids
    with_project do |proj|
      out, err, status = mutineer("run", "calculator.rb", "--dry-run", "--format", "json",
                                  "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      assert_equal Mutineer::Reporter::SCHEMA_VERSION, doc["schema_version"]
      assert_operator doc["mutants"].size, :>, 0
      assert_equal doc["summary"]["total"], doc["mutants"].size
      assert_equal 2, doc["summary"]["id_format"]
      entry = doc["mutants"].first
      assert_equal %w[subject file line operator token id], entry.keys
      assert_match(/\A[0-9a-f]{12}\z/, entry["id"])
      assert_equal "calculator.rb", entry["file"]
      assert doc["summary"].key?("declined")
      assert doc["summary"].key?("declined_by_operator")
      assert doc["summary"].key?("by_operator")
      assert_equal [], doc["summary"]["unmatched_ignores"]
      assert_operator doc["summary"]["by_operator"]["arithmetic"], :>, 0
    end
  end

  def test_dry_run_format_json_ids_match_a_real_run
    with_project do |proj|
      dry_out, dry_err, dry = mutineer("run", "calculator.rb", "--dry-run", "--format", "json",
                                       "--operators", "arithmetic", chdir: proj)
      assert_equal 0, dry.exitstatus, dry_err
      dry_ids = JSON.parse(dry_out)["mutants"].map { |h| h["id"] }.sort

      _, run_err, run = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                 "--operators", "arithmetic", "--format", "json",
                                 "--output", "run.json", chdir: proj)
      assert_equal 0, run.exitstatus, run_err
      report = JSON.parse(File.read(File.join(proj, "run.json")))
      run_ids = (report["killed"] + report["survivors"] + report["no_coverage"] +
                 report["uncapturable"] + report["unplaceable"] + report["ran_at_load"] +
                 report["ignored"]).map { |h| h["id"] }.sort
      assert_equal dry_ids, run_ids
    end
  end

  def test_dry_run_format_json_honors_output
    with_project do |proj|
      out, err, status = mutineer("run", "calculator.rb", "--dry-run", "--format", "json",
                                  "--output", "dry.json", "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_empty out
      assert_includes err, "Report written to"
      doc = JSON.parse(File.read(File.join(proj, "dry.json")))
      assert_operator doc["mutants"].size, :>, 0
    end
  end

  def test_dry_run_format_html_warns_unused
    with_project do |proj|
      out, err, status = mutineer("run", "calculator.rb", "--dry-run", "--format", "html", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "mutations (dry run, not executed)"
      assert_includes err, "--format html has no effect with --dry-run"
    end
  end

  HEREDOC_CONDITION = "class Notes\n  def note(x)\n    if x == <<~S\n      hi\n    S\n      1\n    end\n  end\nend\n"

  def test_dry_run_prints_declined_counts
    with_project do |proj|
      File.write(File.join(proj, "notes.rb"), HEREDOC_CONDITION)
      out, err, status = mutineer("run", "notes.rb", "--dry-run", "--operators", "condition_true", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "1 declined (condition_true: 1)"

      # A repeated operator name runs once, so its decline counts once.
      out, err, status = mutineer("run", "notes.rb", "--dry-run", "--operators", "condition_true,condition_true", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "1 declined (condition_true: 1)"
    end
  end

  def test_dry_run_labels_declined_under_since
    with_project do |proj|
      # The declined heredoc sits on a line the change does not touch.
      File.write(File.join(proj, "notes.rb"), HEREDOC_CONDITION)
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      path = File.join(proj, "calculator.rb")
      File.write(path, File.read(path).sub("a + b", "a + b + 0"))
      out, err, status = mutineer("run", "calculator.rb", "notes.rb", "--dry-run", "--since", "HEAD",
                                  "--operators", "arithmetic,condition_true", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "1 declined in the scanned files (not narrowed by --since) (condition_true: 1)"
    end
  end

  def test_empty_run_names_declined_candidates
    with_project do |proj|
      File.write(File.join(proj, "notes.rb"), HEREDOC_CONDITION)
      _, err, status = mutineer("run", "notes.rb", "--test", "calculator_strong_test.rb",
                                "--operators", "condition_true", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "no mutants were generated. 1 candidate was declined (--dry-run shows the count per operator)."
      refute_includes err, "Check that the sources contain code"
    end
  end

  def test_json_report_carries_declined_counts
    with_project do |proj|
      path = File.join(proj, "calculator.rb")
      File.write(path, File.read(path).sub(/end\s*\z/, "  def note(x)\n    if x == <<~S\n      hi\n    S\n      1\n    end\n  end\nend\n"))
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--operators", "condition_true,arithmetic", "--format", "json",
                                "--output", "r.json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      summary = JSON.parse(File.read(File.join(proj, "r.json")))["summary"]
      assert_equal({ "condition_true" => 1 }, summary["declined_by_operator"])
      assert_equal 1, summary["declined"]
    end
  end

  # --no-since must beat a .mutineer.yml `since:` key end to end, through the
  # real OptionParser wiring. The counterfactual is asserted too: without the
  # flag, the file's unresolvable ref reaches validate_since! and exits 2.
  def test_no_since_overrides_config_file_since
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "since: origin/does-not-exist\n")
      _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                              "--no-since", chdir: proj)
      assert_equal 0, status.exitstatus, "--no-since must neutralize the file's since:"
      _, err, status2 = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                 chdir: proj)
      assert_equal 2, status2.exitstatus, "without --no-since the file's since: applies"
      assert_match(/--since requires a git repository|unknown git ref/, err)
    end
  end

  # --since end to end through the real CLI wiring: the emitted JSON must
  # record summary.scoped, or a scoped report would be written unmarked and
  # the baseline refusal could not recognize it.
  def test_since_run_records_scoped_in_json
    with_project do |proj|
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                              "--since", "HEAD", "--format", "json", "--output", "r.json", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_equal true, JSON.parse(File.read(File.join(proj, "r.json")))["summary"]["scoped"]
    end
  end

  # W1.2 (1.x phase): an empty full scan still exits 0, but says that 2.0
  # fails it unless --allow-empty marks it as expected.
  def test_empty_full_scan_warns_unless_allow_empty
    with_project do |proj|
      args = ["run", "calculator.rb", "--test", "calculator_strong_test.rb", "--operators", "regex"]
      _, err, status = mutineer(*args, chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "no mutants were generated"
      assert_includes err, Mutineer::BECOMES_ERROR_IN_2_0
      assert_includes err, "--allow-empty"

      _, err, status = mutineer(*args, "--allow-empty", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_empty err

      File.write(File.join(proj, ".mutineer.yml"), "allow_empty: true\n")
      _, err, = mutineer(*args, chdir: proj)
      refute_includes err, Mutineer::BECOMES_ERROR_IN_2_0
      _, err, = mutineer(*args, "--no-allow-empty", chdir: proj)
      assert_includes err, Mutineer::BECOMES_ERROR_IN_2_0
    end
  end

  # An empty --since run is a stated success: a pull request that touched no
  # Ruby code has nothing to test, and that is not a mistake.
  def test_empty_since_run_says_nothing_changed_and_does_not_warn
    with_project do |proj|
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--since", "HEAD", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "nothing to test in the changes since HEAD"
      refute_includes err, Mutineer::BECOMES_ERROR_IN_2_0
      refute_includes err, "No mutations generated"
    end
  end

  # A suppressed mutant on an unchanged line is not a mutant the changes hold:
  # the run still says the changes hold nothing to test (PR #235 review).
  def test_empty_since_run_with_a_suppressed_mutant_still_says_nothing_changed
    with_project do |proj|
      path = File.join(proj, "calculator.rb")
      File.write(path, File.read(path).sub("    a + b\n", "    a + b # mutineer:disable-line\n"))
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--since", "HEAD", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "nothing to test in the changes since HEAD"
      refute_includes err, "no covered mutations", "the out-of-scope suppressed mutant must not reach the report"
    end
  end

  # The narrowing keeps a suppressed mutant on a changed line in the report.
  def test_since_run_keeps_a_suppressed_mutant_on_a_changed_line
    with_project do |proj|
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      path = File.join(proj, "calculator.rb")
      File.write(path, File.read(path).sub("    a + b\n", "    a + b # mutineer:disable-line\n"))
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--since", "HEAD", "--format", "json", "--output", "r.json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal 1, JSON.parse(File.read(File.join(proj, "r.json")))["summary"]["ignored"]
    end
  end

  # A --since run that had no mutants before scoping is misconfigured (the
  # operators never match), not "nothing changed", so it gets the warning.
  def test_since_run_with_no_candidates_before_scoping_still_warns
    with_project do |proj|
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--operators", "regex", "--since", "HEAD", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, Mutineer::BECOMES_ERROR_IN_2_0
      refute_includes err, "nothing to test in the changes"
    end
  end

  # An untracked source has no git diff. --since must still mutate it, or a
  # weak suite passes the threshold with zero mutants scored.
  def test_since_keeps_untracked_source_and_fails_a_weak_suite
    with_project do |proj|
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add calculator_weak_test.rb], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                              "--since", "HEAD", "--threshold", "90", "--format", "json",
                              "--output", "r.json", chdir: proj)
      assert_equal 1, status.exitstatus
      assert_operator JSON.parse(File.read(File.join(proj, "r.json")))["summary"]["total"], :>, 0
    end
  end

  def test_json_output_round_trips_to_file
    with_project do |proj|
      _, _, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                              "--format", "json", "--output", "report.json", chdir: proj)
      assert_equal 0, status.exitstatus
      doc = JSON.parse(File.read(File.join(proj, "report.json")))
      assert_equal Mutineer::Reporter::SCHEMA_VERSION, doc["schema_version"]
      assert_equal 100.0, doc["summary"]["score"]
      assert_equal doc["summary"]["killed"], doc["killed"].size
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
      assert_equal 1, status.exitstatus
      assert_includes err, "mutineer: cannot load broken.rb: SyntaxError"
      refute_includes err, "cli.rb:", "no internal backtrace should leak"
    end
  end

  # #288: a load error in the tool process can quote DATABASE_URL. The run
  # prints one redacted line and exits 1, with no backtrace unless --verbose.
  BAD_DATABASE_URL = "postgres://u:s3cret@ho st/db"
  # A boot file that fails the way Rails does on a malformed DATABASE_URL.
  URI_BOOT = %(require "uri"\nURI.parse(ENV.fetch("DATABASE_URL"))\n)

  def run_with_boot(boot_source, *flags)
    with_project do |proj|
      File.write(File.join(proj, "boot.rb"), boot_source)
      return mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--boot", "boot.rb",
                      *flags, chdir: proj, env: { "DATABASE_URL" => BAD_DATABASE_URL })
    end
  end

  def backtrace_lines(err)
    err.lines.grep(/\A\s/)
  end

  # #341: an unexpected error is printed redacted, with exit 1, instead of
  # reaching Ruby's default printer with the raw password.
  def test_unexpected_error_is_redacted_and_exits_1
    cli = Mutineer::CLI.singleton_class
    original = Mutineer::CLI.method(:run)
    cli.send(:define_method, :run) { |_config| raise "cannot connect: s3cret" }
    previous = ENV.fetch("DATABASE_URL", nil)
    ENV["DATABASE_URL"] = BAD_DATABASE_URL
    with_project do |proj|
      status = nil
      _, err = capture_io do
        status = assert_raises(SystemExit) do
          Dir.chdir(proj) { Mutineer::CLI.start(["run", "calculator.rb", "--test", "calculator_strong_test.rb"]) }
        end
      end
      assert_equal 1, status.status
      assert_includes err, "mutineer: "
      assert_includes err, "cannot connect: [REDACTED]"
      refute_includes err, "s3cret"
    end
  ensure
    cli.send(:define_method, :run, original)
    previous ? ENV["DATABASE_URL"] = previous : ENV.delete("DATABASE_URL")
  end

  # A ScriptError (NotImplementedError here) is caught by the last-resort
  # handler too, so it cannot reach Ruby's printer unredacted (#341).
  def test_unexpected_script_error_is_redacted_and_exits_1
    cli = Mutineer::CLI.singleton_class
    original = Mutineer::CLI.method(:run)
    cli.send(:define_method, :run) { |_config| raise NotImplementedError, "adapter: s3cret" }
    previous = ENV.fetch("DATABASE_URL", nil)
    ENV["DATABASE_URL"] = BAD_DATABASE_URL
    with_project do |proj|
      status = nil
      _, err = capture_io do
        status = assert_raises(SystemExit) do
          Dir.chdir(proj) { Mutineer::CLI.start(["run", "calculator.rb", "--test", "calculator_strong_test.rb"]) }
        end
      end
      assert_equal 1, status.status
      assert_includes err, "adapter: [REDACTED]"
      refute_includes err, "s3cret"
    end
  ensure
    cli.send(:define_method, :run, original)
    previous ? ENV["DATABASE_URL"] = previous : ENV.delete("DATABASE_URL")
  end

  # #364 repro (the reporter's files): a run under the default reload
  # strategy kills its one mutant and prints no constant-redefinition warning.
  def test_reload_run_prints_no_constant_redefinition_warnings
    Dir.mktmpdir("mutineer-proj") do |proj|
      %w[constant_reload.rb constant_reload_test.rb].each { |f| FileUtils.cp(File.join(FIXTURES, f), proj) }
      out, err, status = mutineer("run", "constant_reload.rb", "--test", "constant_reload_test.rb",
                                  "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      summary = JSON.parse(out).fetch("summary")
      assert_equal [1, 1, 0], summary.values_at("total", "killed", "survived")
      refute_match(/already initialized constant|previous definition of/, err)
    end
  end

  def test_ambiguous_option_is_a_usage_error
    _, err, status = mutineer("--ver")
    assert_equal 2, status.exitstatus
    assert_match(/\Amutineer: ambiguous option: --ver/, err)
  end

  # The subcommands parse their own options; a malformed one exits 2 there too.
  def test_malformed_subcommand_options_are_usage_errors
    [%w[init --force=1], %w[triage report.json --all=1]].each do |argv|
      _, err, status = mutineer(*argv)
      assert_equal 2, status.exitstatus, "#{argv.join(' ')}: #{err}"
      assert_match(/\Amutineer: needless argument: --(force|all)=1/, err)
    end
  end

  def test_boot_error_hides_the_database_password
    _, err, status = run_with_boot(URI_BOOT)

    assert_equal 1, status.exitstatus, err
    assert_includes err, "mutineer: cannot load boot.rb: URI::InvalidURIError"
    assert_includes err, "[REDACTED]"
    refute_includes err, "s3cret"
    assert_empty backtrace_lines(err)
    assert_includes err, "mutineer: re-run with --verbose for the backtrace and causes"
  end

  def test_boot_error_prints_a_redacted_backtrace_under_verbose
    _, err, status = run_with_boot(URI_BOOT, "--verbose")

    assert_equal 1, status.exitstatus, err
    assert_includes err, "boot.rb:2"
    refute_includes err, "s3cret"
    refute_includes err, "re-run with --verbose"
  end

  def test_boot_error_prints_a_redacted_cause_under_verbose
    boot = <<~RUBY
      require "uri"
      begin
        URI.parse(ENV.fetch("DATABASE_URL"))
      rescue URI::InvalidURIError
        raise "boot failed"
      end
    RUBY
    _, err, status = run_with_boot(boot, "--verbose")

    assert_equal 1, status.exitstatus, err
    assert_includes err, "mutineer: caused by: URI::InvalidURIError"
    assert_includes err, "[REDACTED]"
    refute_includes err, "s3cret"
  end

  def test_boot_load_error_exits_one_cleanly
    _, err, status = run_with_boot(%(require "no_such_gem_288"\n))

    assert_equal 1, status.exitstatus, err
    assert_includes err, "mutineer: cannot load boot.rb: LoadError"
    assert_empty backtrace_lines(err)
  end

  def test_require_file_error_hides_the_password
    with_project do |proj|
      File.write(File.join(proj, "extra.rb"), %(raise "no db: #{BAD_DATABASE_URL}"\n))
      File.write(File.join(proj, ".mutineer.yml"), "require:\n  - extra.rb\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                chdir: proj, env: { "DATABASE_URL" => BAD_DATABASE_URL })

      assert_equal 1, status.exitstatus, err
      assert_includes err, "mutineer: cannot load extra.rb: RuntimeError"
      refute_includes err, "s3cret"
      assert_empty backtrace_lines(err)
    end
  end

  # A non-ASCII path next to a Latin-1 message must not break the message
  # build, or Ruby would print the raw error as the cause.
  def test_boot_error_with_a_non_ascii_path_and_latin1_message_hides_the_password
    with_project do |proj|
      File.write(File.join(proj, "bööt.rb"), %(raise "caf\\xE9 #{BAD_DATABASE_URL}".dup.force_encoding("ISO-8859-1")\n))
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--boot", "bööt.rb",
                                chdir: proj, env: { "DATABASE_URL" => BAD_DATABASE_URL })

      assert_equal 1, status.exitstatus, err
      assert_includes err, "mutineer: cannot load bööt.rb: RuntimeError"
      refute_includes err.b, "s3cret".b
    end
  end

  def test_boot_path_ruby_cannot_expand_stays_a_usage_error
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--boot", "~nosuchuser288/boot.rb", chdir: proj)

      assert_equal 2, status.exitstatus, err
      refute_includes err, "cannot load"
    end
  end

  def test_missing_boot_file_is_a_usage_error
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--boot", "missing_boot.rb", chdir: proj)

      assert_equal 2, status.exitstatus, err
      assert_includes err, "missing_boot.rb"
      refute_includes err, "cannot load"
    end
  end

  def test_missing_boot_file_is_a_usage_error_under_daemon
    with_project do |proj|
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--boot", "missing_boot.rb", "--daemon", chdir: proj)

      assert_equal 2, status.exitstatus, err
      assert_includes err, "missing_boot.rb"
      refute_includes err, "daemon"
    end
  end

  def test_missing_require_file_is_a_usage_error
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "require:\n  - missing_extra.rb\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)

      assert_equal 2, status.exitstatus, err
      assert_includes err, "missing_extra.rb"
      refute_includes err, "cannot load"
    end
  end

  def test_boot_not_implemented_error_exits_one_cleanly
    _, err, status = run_with_boot(%(raise NotImplementedError, "adapter for #{BAD_DATABASE_URL}"\n))

    assert_equal 1, status.exitstatus, err
    assert_includes err, "mutineer: cannot load boot.rb: NotImplementedError"
    refute_includes err, "s3cret"
  end

  # The clean-suite check writes a failing test's report to stderr; a test that
  # fails on a database error can quote DATABASE_URL.
  def test_failing_clean_suite_report_hides_the_password
    with_project do |proj|
      File.write(File.join(proj, "fail_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "calculator"
        class FailTest < Minitest::Test
          def test_db = flunk("no db: \#{ENV.fetch("DATABASE_URL")}")
        end
      RUBY
      _, err, status = mutineer("run", "calculator.rb", "--test", "fail_test.rb",
                                chdir: proj, env: { "DATABASE_URL" => BAD_DATABASE_URL })

      assert_equal 1, status.exitstatus, err
      assert_includes err, "no db: postgres://u:[REDACTED]@ho st/db"
      refute_includes err, "s3cret"
    end
  end

  def test_test_file_load_error_in_the_clean_suite_hides_the_password
    with_project do |proj|
      File.write(File.join(proj, "boom_test.rb"), %(raise "cannot connect: \#{ENV.fetch("DATABASE_URL")}"\n))
      _, err, status = mutineer("run", "calculator.rb", "--test", "boom_test.rb",
                                chdir: proj, env: { "DATABASE_URL" => BAD_DATABASE_URL })

      assert_equal 1, status.exitstatus, err
      assert_includes err, "[mutineer] load failed: RuntimeError: cannot connect: postgres://u:[REDACTED]@ho st/db"
      assert_includes err, "[mutineer] re-run with --verbose for the backtrace"
      refute_includes err, "s3cret"

      _, err, = mutineer("run", "calculator.rb", "--test", "boom_test.rb", "--verbose",
                         chdir: proj, env: { "DATABASE_URL" => BAD_DATABASE_URL })

      assert_includes err, "boom_test.rb:1"
      refute_includes err, "s3cret"
    end
  end

  def test_source_argument_error_at_load_exits_one
    with_project do |proj|
      File.write(File.join(proj, "bad.rb"), %(def one = 1\nraise ArgumentError, "bad #{BAD_DATABASE_URL}"\n))
      _, err, status = mutineer("run", "bad.rb", "--test", "calculator_strong_test.rb",
                                chdir: proj, env: { "DATABASE_URL" => BAD_DATABASE_URL })

      assert_equal 1, status.exitstatus, err
      assert_includes err, "cannot load"
      refute_includes err, "s3cret"
      refute_includes err, "needs other files loaded first"
    end
  end

  # #376: cart.rb reads Shop::Price at load and does not load it. The reported
  # files, copied into a temp project so the run cannot see this checkout.
  SOURCE_NEEDS_BOOT = File.join(FIXTURES, "source_needs_boot")
  # The extra stderr line, word for word. A change to the hint fails this.
  SOURCE_NEEDS_BOOT_LINE = "mutineer: a source that needs other files loaded first takes them from " \
                           "`boot:` (or `--boot`), which loads before the sources; " \
                           "`require:` files load after them"

  def with_source_needs_boot
    Dir.mktmpdir("mutineer-needs-boot") do |proj|
      FileUtils.cp_r("#{SOURCE_NEEDS_BOOT}/.", proj)
      # A file here stops config walk-up from picking up a parent .mutineer.yml.
      File.write(File.join(proj, ".mutineer.yml"), "threshold: 0\n")
      yield proj
    end
  end

  def assert_source_needs_boot(err, path)
    assert_includes err, "mutineer: cannot load #{path}"
    assert_includes err, SOURCE_NEEDS_BOOT_LINE
  end

  # The reporter's gem: running cart.rb alone raises NameError, prints the
  # boot hint, and writes no report. require: still loads after the source.
  def test_source_that_cannot_load_alone_points_at_boot
    with_source_needs_boot do |proj|
      out, err, status = mutineer("run", "lib/shop/cart.rb", "--test", "test/test_cart.rb",
                                  "--format", "json", "--output", "report.json", chdir: proj)
      assert_equal 1, status.exitstatus, err
      assert_equal "", out
      refute File.exist?(File.join(proj, "report.json")), "a load failure writes no report"
      assert_source_needs_boot(err, "lib/shop/cart.rb: NameError: uninitialized constant Shop::Cart::Price")
      assert_includes err, "mutineer: re-run with --verbose for the backtrace and causes"
      assert_empty backtrace_lines(err)

      _, verbose, verbose_status = mutineer("run", "lib/shop/cart.rb", "--test", "test/test_cart.rb",
                                            "--verbose", chdir: proj)
      assert_equal 1, verbose_status.exitstatus, verbose
      assert_source_needs_boot(verbose, "lib/shop/cart.rb: NameError")
      assert_includes verbose, "cart.rb:"
      refute_includes verbose, "re-run with --verbose"

      _, redefine, redefine_status = mutineer("run", "lib/shop/cart.rb", "--test", "test/test_cart.rb",
                                              "--strategy", "redefine", chdir: proj)
      assert_equal 1, redefine_status.exitstatus, redefine
      assert_source_needs_boot(redefine, "lib/shop/cart.rb: NameError")
    end
  end

  # #217: require: loads after the sources, so it cannot define Price first.
  def test_require_does_not_load_before_a_source_that_needs_it
    ["require:\n  - lib/shop.rb\n", "require:\n  - lib/shop/price.rb\n"].each do |yaml|
      with_source_needs_boot do |proj|
        File.write(File.join(proj, ".mutineer.yml"), yaml)
        _, err, status = mutineer("run", "lib/shop/cart.rb", "--test", "test/test_cart.rb", chdir: proj)
        assert_equal 1, status.exitstatus, err
        assert_source_needs_boot(err, "lib/shop/cart.rb: NameError: uninitialized constant Shop::Cart::Price")
        refute_includes err, "cannot load lib/shop.rb"
        refute_includes err, "cannot load lib/shop/price.rb"
      end
    end
  end

  # boot: and --boot load the entry file first, so the one arithmetic mutant
  # (`*` -> `/`) is killed. Listing the entry file as a source does the same.
  def test_boot_runs_a_source_that_cannot_load_alone
    expectations = [
      ["boot: lib/shop.rb\n", []],
      ["threshold: 0\n", ["--boot", "lib/shop.rb"]]
    ]
    expectations.each do |yaml, flags|
      with_source_needs_boot do |proj|
        File.write(File.join(proj, ".mutineer.yml"), yaml)
        out, err, status = mutineer("run", "lib/shop/cart.rb", "--test", "test/test_cart.rb",
                                    "--format", "json", *flags, chdir: proj)
        assert_equal 0, status.exitstatus, err
        refute_includes err, "needs other files loaded first"
        doc = JSON.parse(out)
        assert_equal [1, 1, 100.0], doc["summary"].values_at("total", "killed", "score")
        killed = doc.fetch("killed")
        assert_equal ["Shop::Cart.total", "arithmetic", "*"],
                     killed.fetch(0).values_at("subject", "operator", "token")
      end
    end
  end

  def test_listing_the_entry_file_before_the_source_runs_it
    with_source_needs_boot do |proj|
      out, err, status = mutineer("run", "lib/shop.rb", "lib/shop/cart.rb", "--test", "test/test_cart.rb",
                                  "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      refute_includes err, "needs other files loaded first"
      doc = JSON.parse(out)
      assert_equal [1, 1, 100.0], doc["summary"].values_at("total", "killed", "score")
      assert_equal "Shop::Cart.total", doc.fetch("killed").fetch(0).fetch("subject")
    end
  end

  # The hint is the NameError rule, not the shop example: a missing constant,
  # a missing local, and a missing method.
  def test_name_error_shapes_at_source_load_point_at_boot
    {
      "VALUE = MissingConst376\n" => "NameError",
      "VALUE = unknown_size_376\n" => "NameError",
      "VALUE = nil.no_such_method_376\n" => "NoMethodError"
    }.each do |body, error_class|
      with_project do |proj|
        File.write(File.join(proj, "box.rb"), "class Box\n  #{body}  def self.size = VALUE\nend\n")
        _, err, status = mutineer("run", "box.rb", "--test", "calculator_strong_test.rb", chdir: proj)
        assert_equal 1, status.exitstatus, err
        assert_source_needs_boot(err, "box.rb: #{error_class}")
      end
    end
  end

  # A load error that is not a NameError, and a NameError that is not a source,
  # stay on the old one-line message.
  def test_other_load_errors_do_not_point_at_boot
    {
      "raise 'plain'\n" => "RuntimeError",
      "require 'no_such_gem_376'\n" => "LoadError",
      "raise NotImplementedError, 'adapter'\n" => "NotImplementedError",
      "def oops(\n" => "SyntaxError",
      "begin\n  MissingWrapped376\nrescue NameError\n  raise 'wrapped'\nend\n" => "RuntimeError"
    }.each do |body, error_class|
      with_project do |proj|
        File.write(File.join(proj, "bad.rb"), body)
        _, err, status = mutineer("run", "bad.rb", "--test", "calculator_strong_test.rb", chdir: proj)
        assert_equal 1, status.exitstatus, err
        assert_includes err, "mutineer: cannot load bad.rb: #{error_class}"
        refute_includes err, "needs other files loaded first"
      end
    end

    with_project do |proj|
      File.write(File.join(proj, "boot.rb"), "MissingBoot376\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--boot", "boot.rb", chdir: proj)
      assert_equal 1, status.exitstatus, err
      assert_includes err, "mutineer: cannot load boot.rb: NameError"
      refute_includes err, "needs other files loaded first"
    end

    with_project do |proj|
      File.write(File.join(proj, "extra.rb"), "MissingRequire376\n")
      File.write(File.join(proj, ".mutineer.yml"), "require:\n  - extra.rb\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", chdir: proj)
      assert_equal 1, status.exitstatus, err
      assert_includes err, "mutineer: cannot load extra.rb: NameError"
      refute_includes err, "needs other files loaded first"
    end
  end

  # A dry run parses the source and does not load it, so there is no hint.
  def test_dry_run_does_not_load_a_source_that_cannot_load_alone
    with_source_needs_boot do |proj|
      out, err, status = mutineer("run", "lib/shop/cart.rb", "--dry-run", "--test", "test/test_cart.rb", chdir: proj)
      assert_equal 0, status.exitstatus, err
      refute_includes err, "needs other files loaded first"
      assert_includes out, "Shop::Cart.total"
      assert_includes out, "arithmetic"
    end
  end

  # #8: --verbose is documented and both it and its --debug alias are accepted
  # flags (not "invalid option") — a clean run still exits 0.
  def test_help_documents_verbose
    out, _, status = mutineer("--help")
    assert_equal 0, status.exitstatus
    assert_includes out, "--verbose"
  end

  # #376: --boot is how a gem loads a file that cannot load alone, not a Rails-only flag.
  def test_help_describes_boot_for_a_gem_entry_file
    out, _, status = mutineer("--help")
    assert_equal 0, status.exitstatus
    boot = out.lines.drop_while { |line| !line.include?("--boot FILE") }.take(3).join
    assert_includes boot, "before the sources"
    assert_includes boot, "lib/<name>.rb"
    refute_includes boot, "Rails apps"
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

  # #126: an old-format ignore entry still suppresses its mutant, and the run
  # warns once, naming the new id and scoping the list to this run.
  def test_old_format_ignore_entry_warns_with_the_new_id
    with_project do |proj|
      old, new = calculator_ids(proj)
      File.write(File.join(proj, ".mutineer.yml"), "ignore:\n  - #{old}\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--operators", "arithmetic", "--jobs", "1", chdir: proj)
      assert_equal 0, status.exitstatus, err
      warnings = legacy_warnings(err)
      assert_equal 1, warnings.size, err
      assert_includes warnings.first, old
      assert_includes warnings.first, new
      assert_match(/only mutants in this run's sources and operators/, warnings.first)
      assert_match(/every source/, warnings.first)
      assert_match(/[Rr]eplace/, warnings.first)

      # The JSON report counts the entry, so the Action can annotate it.
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  "--operators", "arithmetic", "--jobs", "1", "--format", "json",
                                  chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal({ "ignore" => 1, "baseline" => 0 }, JSON.parse(out)["summary"]["legacy_id_matches"])
      # A matching old id is in use. It is not also an unmatched entry.
      assert_equal [], JSON.parse(out)["summary"]["unmatched_ignores"]
      assert_empty unmatched_warnings(err)
    end
  end

  def test_new_format_ignore_entry_does_not_warn
    with_project do |proj|
      _, new = calculator_ids(proj)
      File.write(File.join(proj, ".mutineer.yml"), "ignore:\n  - #{new}\n")
      out, err, status = mutineer("run", "calculator.rb", "--dry-run", "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_match(/1 ignored/, out)
      assert_empty legacy_warnings(err)
      assert_empty unmatched_warnings(err)
    end
  end

  # #377: a stale ignore id is named, listed, and does not change the exit code.
  # A current id in the same list is in use, so it is not named. A repeated
  # stale id is named once, in file order.
  def test_run_warns_when_an_ignore_entry_matches_no_mutant
    with_project do |proj|
      _old, current = calculator_ids(proj)
      first = "aaaaaaaaaaaa"
      second = "0123456789ab"
      File.write(File.join(proj, ".mutineer.yml"), <<~YML)
        ignore:
          - #{first}
          - #{current}
          - #{second}
          - #{first}
        operators:
          - arithmetic
      YML
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  "--operators", "arithmetic", "--jobs", "1", "--format", "json",
                                  chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      assert_equal [first, second], doc["summary"]["unmatched_ignores"]
      assert_includes doc["ignored"].map { |row| row["id"] }, current
      assert_equal ["[mutineer] ignore entry #{first} matched no mutant in this run's sources and operators. " \
                    "If those cover its code, the entry is stale: remove it.\n",
                    "[mutineer] ignore entry #{second} matched no mutant in this run's sources and operators. " \
                    "If those cover its code, the entry is stale: remove it.\n"],
                   unmatched_warnings(err)
    end
  end

  # #377: --since narrows after matching, so an entry for a mutant outside the
  # diff is not a miss. A stale id in the same file still is.
  def test_since_does_not_warn_about_an_ignore_outside_the_diff
    with_project do |proj|
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      _old, current = calculator_ids(proj)
      stale = "0123456789ab"
      File.write(File.join(proj, ".mutineer.yml"), <<~YML)
        ignore:
          - #{current}
          - #{stale}
        operators:
          - arithmetic
      YML
      path = File.join(proj, "calculator.rb")
      File.write(path, File.read(path) + "# note\n")
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  "--since", "HEAD", "--operators", "arithmetic", "--jobs", "1",
                                  "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      assert_equal true, doc["summary"]["scoped"]
      assert_equal [stale], doc["summary"]["unmatched_ignores"]
      assert_equal 1, unmatched_warnings(err).size
      assert_includes unmatched_warnings(err).first, stale
      refute_includes unmatched_warnings(err).join, current
    end
  end

  # #377: --only narrows methods before matching, so a miss would not mean the
  # entry is stale. The warning is skipped and the list is empty.
  def test_only_skips_the_unmatched_ignore_warning
    with_project do |proj|
      _old, add_id = calculator_ids(proj)
      stale = "0123456789ab"
      File.write(File.join(proj, ".mutineer.yml"), <<~YML)
        ignore:
          - #{add_id}
          - #{stale}
        operators:
          - arithmetic
      YML
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  "--only", "Calculator#subtract", "--operators", "arithmetic",
                                  "--jobs", "1", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_empty unmatched_warnings(err)
      assert_equal [], JSON.parse(out)["summary"]["unmatched_ignores"]
    end
  end

  # #377: pairing drops a requested source that has no test, but its ignore
  # entries are still in use. A real run and a dry run of the same files
  # list the same unmatched ids. An old-format id in that source still warns
  # as an old id, not as unmatched.
  def test_an_unpaired_source_ignore_is_not_unmatched
    Dir.mktmpdir("mutineer-unpaired") do |proj|
      FileUtils.mkdir_p(File.join(proj, "lib"))
      FileUtils.mkdir_p(File.join(proj, "test"))
      File.write(File.join(proj, "lib/a.rb"), "class A\n  def f(x) = x + 1\nend\n")
      File.write(File.join(proj, "lib/b.rb"), "class B\n  def f(x) = x + 1\nend\n")
      File.write(File.join(proj, "test/a_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/a"
        class ATest < Minitest::Test
          def test_f = assert_equal(2, A.new.f(1))
        end
      RUBY
      b_path = File.join(proj, "lib/b.rb")
      source = File.read(b_path)
      subject = Mutineer::Project.discover([b_path]).find do |item|
        Mutineer::Mutators::Arithmetic.new.mutations_for(item, source).any?
      end
      mutation = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first
      new_id = Mutineer::MutantId.for(subject, mutation, source, path: "lib/b.rb")
      old_id = Mutineer::MutantId.legacy_for(subject, mutation, source)
      stale = "0123456789ab"
      File.write(File.join(proj, ".mutineer.yml"), <<~YML)
        ignore:
          - #{new_id}
          - #{old_id}
          - #{stale}
        operators:
          - arithmetic
      YML

      out, err, status = mutineer("run", "lib/a.rb", "lib/b.rb", "--jobs", "1", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "no test found by convention for lib/b.rb"
      assert_equal [stale], JSON.parse(out)["summary"]["unmatched_ignores"]
      assert_equal [stale], unmatched_warnings(err).map { |line| line[/[0-9a-f]{12}/] }
      assert_equal 1, legacy_warnings(err).size
      assert_includes legacy_warnings(err).first, old_id
      refute_includes unmatched_warnings(err).join, new_id

      dry_out, dry_err, dry = mutineer("run", "lib/a.rb", "lib/b.rb", "--dry-run", "--format", "json", chdir: proj)
      assert_equal 0, dry.exitstatus, dry_err
      assert_equal [stale], JSON.parse(dry_out)["summary"]["unmatched_ignores"]
      assert_equal unmatched_warnings(err), unmatched_warnings(dry_err)
      assert_includes legacy_warnings(dry_err).join, old_id
    end
  end

  # #377: a run of one file warns about an entry whose mutant is in another
  # file. The text says the list covers only this run. Both files do not warn.
  def test_a_file_subset_warns_about_an_entry_in_another_file
    Dir.mktmpdir("mutineer-subset") do |proj|
      %w[a b].each do |name|
        File.write(File.join(proj, "#{name}.rb"), "class #{name.upcase}\n  def f(x) = x + 1\nend\n")
      end
      b_id = arithmetic_new_id(File.join(proj, "b.rb"), "b.rb")
      File.write(File.join(proj, ".mutineer.yml"), "ignore:\n  - #{b_id}\noperators:\n  - arithmetic\n")

      out, err, status = mutineer("run", "a.rb", "--dry-run", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal [b_id], JSON.parse(out)["summary"]["unmatched_ignores"]
      assert_includes unmatched_warnings(err).join, "this run's sources and operators"
      assert_includes unmatched_warnings(err).join, "If those cover its code, the entry is stale: remove it."

      out, err, status = mutineer("run", "a.rb", "b.rb", "--dry-run", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal [], JSON.parse(out)["summary"]["unmatched_ignores"]
      assert_empty unmatched_warnings(err)
    end
  end

  # #377: a dropped repeat's id is still current, so it is not an unmatched entry.
  def test_a_dropped_copy_ignore_is_not_unmatched
    Dir.mktmpdir("mutineer-dropped") do |root|
      path = File.join(root, "str.rb")
      File.write(path, "class Str\n  def a\n    \"hi\"\n  end\nend\n")
      ops = %w[literal_mutation string_literal]
      classes = Mutineer::MutatorRegistry.resolve(ops)
      string_only = Mutineer::Config.new(sources: [path], project_root: root, operators: %w[string_literal])
      dropped_id, old_id = Mutineer::JobPlan.collect_jobs(
        string_only, Mutineer::MutatorRegistry.resolve(%w[string_literal])
      ).last[:id_map].first
      stale = "0123456789ab"
      config = Mutineer::Config.new(sources: [path], project_root: root, operators: ops,
                                    ignore: [stale, dropped_id, old_id, stale])
      extras = Mutineer::JobPlan.collect_jobs(config, classes).last
      assert_equal [stale], Mutineer::CLI.unmatched_ignore_ids(config, extras)
      narrowed = Mutineer::Config.new(sources: [path], project_root: root, operators: ops,
                                      ignore: [stale, dropped_id], only: "Str#other")
      assert_equal [], Mutineer::CLI.unmatched_ignore_ids(narrowed, extras)

      File.write(File.join(root, ".mutineer.yml"), "ignore:\n  - #{dropped_id}\noperators:\n  - literal_mutation\n  - string_literal\n")
      _out, err, status = mutineer("run", "str.rb", "--dry-run", chdir: root)
      assert_equal 0, status.exitstatus, err
      assert_empty unmatched_warnings(err)
    end
  end

  # The new id of the first arithmetic mutant, relative to the run directory.
  def arithmetic_new_id(path, relative)
    source = File.read(path)
    subject = Mutineer::Project.discover([path]).find do |item|
      Mutineer::Mutators::Arithmetic.new.mutations_for(item, source).any?
    end
    mutation = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first
    Mutineer::MutantId.for(subject, mutation, source, path: relative)
  end

  # --dry-run --since prints the same old-format warnings as a real run. No
  # ignored count is compared: a real run does not narrow ignored results.
  def test_dry_run_with_since_prints_the_same_legacy_warnings
    with_project do |proj|
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      old, = calculator_ids(proj)
      File.write(File.join(proj, ".mutineer.yml"), "ignore:\n  - #{old}\n")
      _, dry_err, dry = mutineer("run", "calculator.rb", "--dry-run", "--since", "HEAD",
                                 "--operators", "arithmetic", chdir: proj)
      _, run_err, run = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                 "--since", "HEAD", "--operators", "arithmetic", "--jobs", "1", chdir: proj)
      assert_equal 0, dry.exitstatus, dry_err
      assert_equal 0, run.exitstatus, run_err
      refute_empty legacy_warnings(dry_err)
      assert_equal legacy_warnings(run_err), legacy_warnings(dry_err)
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
      assert_equal Mutineer::Reporter::SCHEMA_VERSION, doc["schema_version"]
      per = doc["per_source"].sort_by { |h| h["file"] }
      assert_equal ["lib/calc.rb", "lib/greeter.rb"], per.map { |h| h["file"] }
      assert_equal 100.0, per.find { |h| h["file"] == "lib/greeter.rb" }["score"]
      assert_operator per.find { |h| h["file"] == "lib/calc.rb" }["score"], :<, 100.0
    end
  end

  # #104: `./lib/calc.rb`, its absolute path and `lib/calc.rb` pair with the
  # same test, and given together they run the source once.
  def test_equivalent_source_spellings_autopair_once
    with_autopair_project do |proj|
      out, err, status = mutineer("run", "./lib/calc.rb", File.join(proj, "lib/calc.rb"), "lib/calc.rb",
                                  "--format", "json", chdir: proj)
      refute_includes err, "no test found"
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      assert_equal ["lib/calc.rb"], doc["per_source"].map { |h| h["file"] }

      single, = mutineer("run", "lib/calc.rb", "--format", "json", chdir: proj)
      assert_equal JSON.parse(single)["summary"]["total"], doc["summary"]["total"]

      explicit, err, status = mutineer("run", "./lib/calc.rb", "--test", "./test/calc_test.rb",
                                       "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal JSON.parse(single)["summary"], JSON.parse(explicit)["summary"]
    end
  end

  def test_autopair_records_unpaired_sources
    Dir.mktmpdir do |proj|
      FileUtils.mkdir_p(File.join(proj, "app/foo"))
      FileUtils.mkdir_p(File.join(proj, "test/foo"))
      File.write(File.join(proj, "app/foo/bar.rb"), "class Bar; def n(a); a + 1; end; end\n")
      File.write(File.join(proj, "test/foo/bar_test.rb"), "class BarTest; end\n")
      File.write(File.join(proj, "app/foo/lone.rb"), "class Lone; def n(a); a + 1; end; end\n")
      cfg = Mutineer::Config.new(sources: ["app/foo/bar.rb", "app/foo/lone.rb"], project_root: proj)
      _out, err = capture_io { Mutineer::CLI.autopair!(cfg) }
      assert_equal ["app/foo/bar.rb"], cfg.sources
      assert_equal ["app/foo/lone.rb"], cfg.unpaired_sources
      assert_includes err, "app/foo/lone.rb"
    end
  end

  def test_autopair_with_explicit_test_records_no_unpaired_source
    Dir.mktmpdir do |proj|
      FileUtils.mkdir_p(File.join(proj, "app/foo"))
      File.write(File.join(proj, "app/foo/lone.rb"), "class Lone; def n(a); a + 1; end; end\n")
      cfg = Mutineer::Config.new(sources: ["app/foo/lone.rb"], tests: ["test/foo/bar_test.rb"], project_root: proj)
      Mutineer::CLI.autopair!(cfg)
      assert_equal [], cfg.unpaired_sources
      assert_equal ["app/foo/lone.rb"], cfg.sources
    end
  end

  def test_unpaired_sources_are_counted_on_every_backend
    with_autopair_project do |proj|
      File.write(File.join(proj, "lib/orphan.rb"), "class Orphan; def z(a); a + 1; end; end\n")
      File.write(File.join(proj, "lib/blank.rb"), "class Blank; end\n")
      [[], ["--test-command", "true %{files}"]].each do |backend|
        out, err, status = mutineer("run", "lib", "--format", "json", *backend, chdir: proj)
        assert_equal 0, status.exitstatus, err
        doc = JSON.parse(out)
        assert_equal 2, doc["summary"]["unpaired_sources"]
        assert_equal 1, doc["summary"]["unpaired_mutants"]
        assert_equal [
          { "file" => "lib/blank.rb", "mutants" => 0 },
          { "file" => "lib/orphan.rb", "mutants" => 1 }
        ], doc["unpaired_sources"]
        assert_equal 2, doc["summary"]["total"]
        assert_equal ["lib/calc.rb", "lib/greeter.rb"], doc["per_source"].map { |row| row["file"] }.sort
        assert_includes err, "lib/orphan.rb"
        assert_includes err, "lib/blank.rb"
      end
    end
  end

  def test_explicit_test_leaves_no_unpaired_source
    with_autopair_project do |proj|
      File.write(File.join(proj, "lib/orphan.rb"), "class Orphan; def z(a); a + 1; end; end\n")
      out, err, status = mutineer("run", "lib", "--test", "test/calc_test.rb", "--format", "json",
                                  "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      assert_equal 0, doc["summary"]["unpaired_sources"]
      assert_equal 0, doc["summary"]["unpaired_mutants"]
      assert_equal [], doc["unpaired_sources"]
      assert_includes doc["per_source"].map { |row| row["file"] }, "lib/orphan.rb"
    end
  end

  def test_unpaired_count_failure_does_not_fail_the_run
    with_autopair_project do |proj|
      Dir.mkdir(File.join(proj, "lib/odd.rb"))
      out, err, status = mutineer("run", "lib", "--format", "json", "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      row = doc["unpaired_sources"].find { |item| item["file"] == "lib/odd.rb" }
      assert_nil row["mutants"]
      assert_includes err, "lib/odd.rb"
      assert_includes err, "could not count the mutants"
      assert_includes err, "no test found by convention for lib/odd.rb"
    end
  end

  def test_empty_run_names_unpaired_mutants
    Dir.mktmpdir do |proj|
      FileUtils.mkdir_p(File.join(proj, "lib"))
      FileUtils.mkdir_p(File.join(proj, "test"))
      File.write(File.join(proj, "lib/plain.rb"), "class Plain; def n(a); a + 1; end; end\n")
      File.write(File.join(proj, "test/plain_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/plain"
        class PlainTest < Minitest::Test
          def test_n
            assert_equal 2, Plain.new.n(1)
          end
        end
      RUBY
      File.write(File.join(proj, "lib/orphan.rb"), "class Orphan; def z(a, b, c); [a > 1, b < 2, c == 3]; end; end\n")
      _out, err, status = mutineer("run", "lib", "--operators", "comparison", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "no mutant ran. 3 mutants are in sources with no paired test"
      refute_includes err, "no mutants were generated"
      refute_includes err, "were not run"
    end
  end

  def test_empty_run_with_failed_unpaired_count_does_not_say_no_mutants
    _out, err = capture_io do
      Mutineer::CLI.warn_empty_run(Mutineer::Config.new, {}, { "lib/odd.rb" => nil })
    end
    assert_includes err,
                    "no mutant ran. 1 source has no paired test; the mutant count is unavailable for 1 of them"
    refute_includes err, "no mutants were generated"
  end

  # A zero count next to a failed count still names every unpaired source.
  def test_empty_run_names_all_unpaired_sources_when_one_count_failed
    _out, err = capture_io do
      Mutineer::CLI.warn_empty_run(Mutineer::Config.new, {}, { "lib/a.rb" => 0, "lib/b.rb" => nil })
    end
    assert_includes err,
                    "no mutant ran. 2 sources have no paired test; the mutant count is unavailable for 1 of them"
    refute_includes err, "no mutants were generated"
  end

  def test_since_run_counts_unpaired_mutants_on_changed_lines
    with_autopair_project do |proj|
      File.write(File.join(proj, "lib/orphan.rb"), "class Orphan; def z(a); a + 1; end; end\n")
      [%w[init -q], %w[config user.email t@t], %w[config user.name t],
       %w[add .], %w[commit -qm base]].each do |args|
        assert system("git", "-C", proj, *args, out: File::NULL, err: File::NULL), "git #{args.first}"
      end
      File.write(File.join(proj, "lib/orphan.rb"), "class Orphan; def z(a); a + 2; end; end\n")
      out, err, status = mutineer("run", "lib", "--since", "HEAD", "--format", "json",
                                  "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      assert_equal 1, doc["summary"]["unpaired_mutants"]
      assert_equal [{ "file" => "lib/orphan.rb", "mutants" => 1 }], doc["unpaired_sources"]

      File.write(File.join(proj, "lib/orphan.rb"), "class Orphan; def z(a); a + 1; end; end\n")
      greeter = File.join(proj, "lib/greeter.rb")
      File.write(greeter, File.read(greeter).sub("def double(n)", "def double(n) # touched"))
      out, err, status = mutineer("run", "lib", "--since", "HEAD", "--format", "json",
                                  "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      assert_equal 0, doc["summary"]["unpaired_mutants"]
      assert_equal [{ "file" => "lib/orphan.rb", "mutants" => 0 }], doc["unpaired_sources"]
    end
  end

  def test_dry_run_counts_unpaired_mutants
    with_autopair_project do |proj|
      File.write(File.join(proj, "lib/orphan.rb"), "class Orphan; def z(a); a + 1; end; end\n")
      File.write(File.join(proj, "lib/blank.rb"), "class Blank; end\n")
      out, err, status = mutineer("run", "lib", "--dry-run", "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "lib/orphan.rb"
      assert_includes out, "1 unpaired (2 sources have no paired test; a run without --test skips them)"
    end
  end

  def test_dry_run_unpaired_count_matches_the_run
    with_autopair_project do |proj|
      File.write(File.join(proj, "lib/orphan.rb"), "class Orphan; def z(a); a + 1; end; end\n")
      File.write(File.join(proj, "lib/blank.rb"), "class Blank; end\n")
      dry, err, status = mutineer("run", "lib", "--dry-run", "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      out, err, status = mutineer("run", "lib", "--format", "json", "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      listed = dry[/(\d+) unpaired \(2 sources have no paired test/]
      assert_equal JSON.parse(out)["summary"]["unpaired_mutants"], listed.to_i
    end
  end

  def test_dry_run_with_explicit_test_reports_zero_unpaired
    with_autopair_project do |proj|
      out, err, status = mutineer("run", "lib", "--test", "test/calc_test.rb", "--dry-run",
                                  "--operators", "arithmetic", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes out, "; 0 unpaired"
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

  # Copy the concern fixture. Its test lives at the namespace path.
  def with_concern_namespace_project
    Dir.mktmpdir("mutineer-concern") do |proj|
      FileUtils.cp_r(File.join(FIXTURES, "concern_namespace", "."), proj)
      yield proj
    end
  end

  # A concern with only a namespace test is scored. The run does not skip it.
  def test_concern_pairs_with_its_namespace_test_and_is_scored
    with_concern_namespace_project do |proj|
      out, err, status = mutineer("run", "app/models/concerns/storage/totaled.rb",
                                  "--matrix", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      refute_includes err, "no test found by convention"
      doc = JSON.parse(out)
      assert_equal ["app/models/concerns/storage/totaled.rb"], doc["per_source"].map { |h| h["file"] }
      assert_equal 1, doc.dig("summary", "total")
      assert_equal 1, doc.dig("summary", "killed")
      assert_equal 100.0, doc.dig("summary", "score")
      assert_equal [{ "file" => "test/models/storage/totaled_test.rb",
                      "name" => "TotaledTest#test_total",
                      "id" => "TotaledTest#test_total",
                      "kills" => 1 }], doc.dig("matrix", "tests")
      row = doc.dig("matrix", "mutants").find { |item| item["status"] == "killed" }
      assert_equal [0], row["killed_by"]
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

  # #87: bar_*_test.rb is the suite when bar_test.rb does not exist. The source
  # must run, not be skipped as if it had no tests.
  def test_split_test_files_are_paired_and_run
    Dir.mktmpdir("mutineer-split") do |proj|
      FileUtils.mkdir_p(File.join(proj, "app/foo"))
      FileUtils.mkdir_p(File.join(proj, "test/foo"))
      File.write(File.join(proj, "app/foo/bar.rb"), "class Bar\n  def n(a)\n    a + 1\n  end\nend\n")
      File.write(File.join(proj, "test/foo/bar_upsert_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../../app/foo/bar"
        class BarUpsertTest < Minitest::Test
          def test_n
            assert_equal 2, Bar.new.n(1)
          end
        end
      RUBY
      out, err, status = mutineer("run", "app/foo/bar.rb", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      refute_includes err, "no test found by convention"
      doc = JSON.parse(out)
      assert_equal ["app/foo/bar.rb"], doc["per_source"].map { |h| h["file"] }
      assert_operator doc["summary"]["killed"], :>, 0
    end
  end

  def test_autopair_keeps_every_split_file
    Dir.mktmpdir("mutineer-split-list") do |proj|
      FileUtils.mkdir_p(File.join(proj, "app/foo"))
      FileUtils.mkdir_p(File.join(proj, "test/foo"))
      File.write(File.join(proj, "app/foo/bar.rb"), "class Bar; def n(a); a + 1; end; end\n")
      %w[bar_guards_test.rb bar_upsert_test.rb].each do |name|
        File.write(File.join(proj, "test/foo", name), "# #{name}\n")
      end
      config = config_resolved_by_cli(proj, "run", "app/foo/bar.rb")
      Mutineer::CLI.autopair!(config)
      assert_equal ["app/foo/bar.rb"], config.sources
      assert_equal ["test/foo/bar_guards_test.rb", "test/foo/bar_upsert_test.rb"], config.tests
    end
  end

  # #380: the temp fixture drops test/models so a later file there cannot change these lists.
  def with_test_expand_project
    with_autopair_project do |proj|
      FileUtils.rm_rf(File.join(proj, "test", "models"))
      yield proj
    end
  end

  def test_a_test_directory_expands_and_matches_the_file_list
    with_test_expand_project do |proj|
      config = config_resolved_by_cli(proj, "run", "lib", "--test", "test")
      assert_equal ["test/calc_test.rb", "test/greeter_test.rb"], config.tests

      listed, = mutineer("run", "lib", "--test", "test/calc_test.rb", "--test", "test/greeter_test.rb",
                         "--format", "json", chdir: proj)
      out, err, status = mutineer("run", "lib", "--test", "test", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "[mutineer] --test test: 2 test files"
      assert_equal JSON.parse(listed)["summary"], JSON.parse(out)["summary"]
      assert_equal JSON.parse(listed)["per_source"], JSON.parse(out)["per_source"]
    end
  end

  def test_a_quoted_test_glob_selects_the_same_files
    with_test_expand_project do |proj|
      config = config_resolved_by_cli(proj, "run", "lib/calc.rb", "--test", "test/*_test.rb")
      assert_equal ["test/calc_test.rb", "test/greeter_test.rb"], config.tests
    end
  end

  def test_a_typed_file_wins_over_the_same_file_from_a_directory
    with_test_expand_project do |proj|
      config = config_resolved_by_cli(proj, "run", "lib", "--test", "./test/calc_test.rb", "--test", "test")
      assert_equal ["./test/calc_test.rb", "test/greeter_test.rb"], config.tests

      _, err, status = mutineer("run", "--dry-run", "lib", "--test", "./test/calc_test.rb", "--test", "test",
                                chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal 1, err.lines.grep(/\[mutineer\] --test /).size
      assert_includes err, "[mutineer] --test test: 2 test files"
      refute_includes err, "--test ./test/calc_test.rb:"
    end
  end

  def test_a_spec_directory_selects_specs_and_detects_rspec
    with_test_expand_project do |proj|
      FileUtils.mkdir_p(File.join(proj, "spec", "nested"))
      File.write(File.join(proj, "spec", "calc_spec.rb"), <<~RUBY)
        require_relative "../lib/calc"

        RSpec.describe Calc do
          it "adds" do
            expect(Calc.new.add(2, 3)).to eq(5)
          end
        end
      RUBY
      File.write(File.join(proj, "spec", "nested", "greeter_spec.rb"), <<~RUBY)
        RSpec.describe "greeter" do
          it "passes" do
            expect(true).to eq(true)
          end
        end
      RUBY
      File.write(File.join(proj, "spec", "spec_helper.rb"), "# helper\n")

      config = config_resolved_by_cli(proj, "run", "lib/calc.rb", "--test", "spec")
      assert_equal ["spec/calc_spec.rb", "spec/nested/greeter_spec.rb"], config.tests
      assert_equal "rspec", config.framework

      kept = config_resolved_by_cli(proj, "run", "lib/calc.rb", "--framework", "minitest", "--test", "spec")
      assert_equal "minitest", kept.framework

      out, err, status = mutineer("run", "lib/calc.rb", "--test", "spec", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal 1, JSON.parse(out)["summary"]["killed"]
    end
  end

  def test_a_blank_or_empty_test_value_exits_two
    with_test_expand_project do |proj|
      FileUtils.mkdir_p(File.join(proj, "empty"))
      ["", "nowhere/*_test.rb", "empty"].each do |value|
        out, err, status = mutineer("run", "lib/calc.rb", "--test", value, "--format", "json", chdir: proj)
        assert_equal 2, status.exitstatus, err
        assert_empty out
        dry_out, dry_err, dry = mutineer("run", "--dry-run", "lib/calc.rb", "--test", value, chdir: proj)
        assert_equal 2, dry.exitstatus, dry_err
        assert_empty dry_out
      end

      _, blank_err, = mutineer("run", "lib/calc.rb", "--test", "", chdir: proj)
      assert_includes blank_err, 'mutineer: --test must name a file, a directory or a glob, not blank (got: "")'
      _, glob_err, = mutineer("run", "lib/calc.rb", "--test", "nowhere/*_test.rb", chdir: proj)
      assert_includes glob_err, "mutineer: --test nowhere/*_test.rb matched no test files"
      refute_includes glob_err, "A directory gives"
      _, dir_err, = mutineer("run", "lib/calc.rb", "--test", "empty", chdir: proj)
      assert_includes dir_err, "mutineer: --test empty matched no test files"
      assert_includes dir_err, "A directory gives the files under it named *_test.rb, *_spec.rb or test_*.rb."
    end
  end

  def test_a_missing_test_file_still_says_no_such_file
    with_test_expand_project do |proj|
      _, err, status = mutineer("run", "lib/calc.rb", "--test", "test/nope_test.rb", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "no such file: test/nope_test.rb"
    end
  end

  def test_dry_run_of_a_test_directory_prints_the_count
    with_test_expand_project do |proj|
      _, err, status = mutineer("run", "--dry-run", "lib", "--test", "test", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "[mutineer] --test test: 2 test files"
    end
  end

  def test_one_test_file_uses_the_singular_count
    with_test_expand_project do |proj|
      FileUtils.rm(File.join(proj, "test", "greeter_test.rb"))
      _, err, status = mutineer("run", "--dry-run", "lib/calc.rb", "--test", "test", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "[mutineer] --test test: 1 test file"
    end
  end

  def test_test_command_keeps_a_directory_and_expands_a_glob
    with_test_expand_project do |proj|
      log = File.join(proj, "args.txt")
      File.write(File.join(proj, "record.rb"), "File.open(#{log.dump}, 'a') { |f| f.puts ARGV }\n")
      command = "#{RbConfig.ruby} record.rb %{files}"

      _, err, status = mutineer("run", "lib/calc.rb", "--test", "test", "--test-command", command, chdir: proj)
      assert_equal 0, status.exitstatus, err
      refute_match(/\[mutineer\] --test /, err)
      # The runner passes an absolute path. It does not expand the directory.
      recorded = File.read(log).lines.map { |line| File.realpath(line.strip) }.uniq
      assert_equal [File.realpath(File.join(proj, "test"))], recorded

      File.write(log, "")
      _, glob_err, glob_status = mutineer("run", "lib/calc.rb", "--test", "test/*_test.rb",
                                          "--test-command", command, chdir: proj)
      assert_equal 0, glob_status.exitstatus, glob_err
      assert_includes glob_err, "[mutineer] --test test/*_test.rb: 2 test files"
      files = ["test/calc_test.rb", "test/greeter_test.rb"].map { |path| File.realpath(File.join(proj, path)) }
      assert_equal files, File.read(log).lines.map { |line| File.realpath(line.strip) }.uniq.sort
    end
  end

  # A bad --test-command is reported before an unmatched --test glob.
  def test_test_command_error_comes_before_a_test_glob_error
    with_test_expand_project do |proj|
      _, err, status = mutineer("run", "lib/calc.rb", "--test", "nowhere/*_test.rb",
                                "--test-command", "rake test", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "must contain %{files}"
      refute_includes err, "matched no test files"
    end
  end

  # With --test-command, an empty directory stays one path. The run does not exit 2.
  def test_test_command_keeps_an_empty_directory
    with_test_expand_project do |proj|
      FileUtils.mkdir_p(File.join(proj, "empty"))
      _, err, status = mutineer("run", "--dry-run", "lib/calc.rb", "--test", "empty",
                                "--test-command", "true %{files}", chdir: proj)
      assert_equal 0, status.exitstatus, err
      refute_includes err, "matched no test files"
    end
  end

  def test_help_names_a_test_directory
    out, _, status = mutineer("--help")
    assert_equal 0, status.exitstatus
    assert_includes out, "--test PATH"
    assert_includes out, "directory"
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

  # --- #382 tests: map in .mutineer.yml --------------------------------------

  CONCERNS_TO_CONTROLLER_TESTS = <<~YAML
    tests:
      - sources: "app/controllers/concerns/**/*.rb"
        tests: "test/controllers/**/*_test.rb"
  YAML

  # Copy the test_map fixture and write `.mutineer.yml` for one scenario.
  # Always write a file so walk-up discovery cannot pick a parent `.mutineer.yml`.
  def with_test_map_project(yaml = CONCERNS_TO_CONTROLLER_TESTS)
    Dir.mktmpdir("mutineer-test-map") do |proj|
      FileUtils.cp_r(File.join(FIXTURES, "test_map", "."), proj)
      File.write(File.join(proj, ".mutineer.yml"), yaml || "threshold: 0\n")
      yield proj
    end
  end

  # AE1 / R6, R7: an unpaired concern joins the run via the map; the matrix
  # names the controller test as its killer.
  def test_tests_map_brings_an_unpaired_source_into_the_run
    with_test_map_project do |proj|
      out, err, status = mutineer("run", "app/controllers", "--format", "json", "--matrix",
                                  chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      files = doc["per_source"].map { |h| h["file"] }
      assert_includes files, "app/controllers/concerns/board_scoped.rb"
      refute_includes err, "no test found by convention for app/controllers/concerns/board_scoped.rb"

      tests = doc.dig("matrix", "tests")
      killed = doc.dig("matrix", "mutants").select do |row|
        row["file"] == "app/controllers/concerns/board_scoped.rb" && row["status"] == "killed"
      end
      refute_empty killed, "expected killed mutants in board_scoped.rb"
      killer_files = killed.flat_map { |row| row["killed_by"] }.map { |i| tests[i]["file"] }.uniq
      assert_includes killer_files, "test/controllers/boards_controller_test.rb"
    end
  end

  # AE2 / R7, R11: a models-only run keeps only the paired model test.
  def test_tests_map_adds_nothing_when_no_mapped_source_runs
    with_test_map_project do |proj|
      config = config_resolved_by_cli(proj, "run", "app/models")
      Mutineer::CLI.autopair!(config)
      assert_equal ["test/models/board_test.rb"], config.tests
    end
  end

  # AE6 / R6, R10: paired test first, then mapped; no duplicate path.
  def test_tests_map_keeps_paired_tests_first
    with_test_map_project do |proj|
      config = config_resolved_by_cli(proj, "run",
                                     "app/controllers/concerns/authentication.rb")
      Mutineer::CLI.autopair!(config)
      assert_equal "test/controllers/concerns/authentication_test.rb", config.tests.first
      assert_equal config.tests, config.tests.uniq
      assert_operator config.tests.size, :>, 1
    end
  end

  # AE3 / R9: --test replaces the map; reports match a run with no map, plus
  # one "no effect" stderr line when the file holds entries.
  def test_explicit_test_replaces_the_tests_map
    with_test_map_project do |proj|
      out_map, err_map, status_map = mutineer(
        "run", "app", "--test", "test/models/board_test.rb", "--format", "json", chdir: proj
      )
      assert_equal 0, status_map.exitstatus, err_map
      assert_includes err_map, "[mutineer] tests in .mutineer.yml has no effect when --test is given"

      File.write(File.join(proj, ".mutineer.yml"), "threshold: 0\n")
      out_plain, err_plain, status_plain = mutineer(
        "run", "app", "--test", "test/models/board_test.rb", "--format", "json", chdir: proj
      )
      assert_equal 0, status_plain.exitstatus, err_plain
      refute_includes err_plain, "has no effect when --test is given"
      assert_equal JSON.parse(out_plain), JSON.parse(out_map)
    end
  end

  # AE4 / R5: an unmatched tests pattern exits 2 for run and dry-run; --test
  # skips the check (R9) and exits 0.
  def test_tests_map_pattern_without_a_match_exits_two
    yaml = <<~YAML
      tests:
        - sources: "app/controllers/concerns/**/*.rb"
          tests: "test/controlers/**/*_test.rb"
    YAML
    with_test_map_project(yaml) do |proj|
      _, err, status = mutineer("run", "app/controllers", "--format", "json", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "tests entry 1"
      assert_includes err, "tests"
      assert_includes err, "test/controlers/**/*_test.rb"

      _, dry_err, dry = mutineer("run", "--dry-run", "app/controllers", chdir: proj)
      assert_equal 2, dry.exitstatus
      assert_includes dry_err, "tests entry 1"

      out, err_ok, ok = mutineer("run", "app/models/board.rb",
                                 "--test", "test/models/board_test.rb",
                                 "--format", "json", chdir: proj)
      assert_equal 0, ok.exitstatus, err_ok
      assert_operator JSON.parse(out)["summary"]["killed"], :>, 0
    end
  end

  # AE5 / R2: a malformed tests: value is a usage error naming the file and entry.
  def test_malformed_tests_map_exits_two
    with_test_map_project("tests: [test/a_test.rb]\n") do |proj|
      _, err, status = mutineer("run", "app/models/board.rb", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, ".mutineer.yml"
      assert_includes err, "entry 1"
      assert_includes err, "mapping with sources and tests"
    end
  end

  # R6: a source with neither paired nor mapped tests still gets today's skip.
  def test_source_without_paired_or_mapped_test_is_still_skipped
    with_test_map_project do |proj|
      File.write(File.join(proj, "app/models/orphan.rb"),
                 "class Orphan; def z(a); a + 1; end; end\n")
      out, err, status = mutineer("run", "app/models", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "[mutineer] no test found by convention for app/models/orphan.rb; skipping"
      refute_includes JSON.parse(out)["per_source"].map { |h| h["file"] }, "app/models/orphan.rb"
    end
  end

  # R12: dry-run checks the map but pairs nothing; mutant listing matches no map.
  def test_dry_run_lists_the_same_mutants_with_a_tests_map
    with_test_map_project do |proj|
      with_map, err_map, status_map = mutineer("run", "--dry-run", "app/models", chdir: proj)
      assert_equal 0, status_map.exitstatus, err_map

      File.write(File.join(proj, ".mutineer.yml"), "threshold: 0\n")
      without_map, err_plain, status_plain = mutineer("run", "--dry-run", "app/models",
                                                      chdir: proj)
      assert_equal 0, status_plain.exitstatus, err_plain
      assert_equal without_map, with_map
    end
  end

  # R12: --test-command reads the same run test list the map fills.
  # Load every %{files} path: plain `ruby a.rb b.rb` only runs `a.rb`.
  def test_tests_map_applies_under_test_command
    with_test_map_project do |proj|
      log = File.join(proj, "args.txt")
      wrapper = File.join(proj, "run_all.rb")
      File.write(wrapper, <<~RUBY)
        File.open(#{log.dump}, "a") { |f| ARGV.each { |path| f.puts path } }
        ARGV.each { |path| load path }
      RUBY
      command = "#{RbConfig.ruby} #{wrapper} %{files}"
      out, err, status = mutineer(
        "run", "app/controllers/concerns/board_scoped.rb",
        "--test-command", command, "--format", "json", chdir: proj
      )
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      assert_equal ["app/controllers/concerns/board_scoped.rb"],
                   doc["per_source"].map { |h| h["file"] }
      assert_operator doc["summary"]["killed"], :>, 0
      recorded = File.read(log).lines.map { |line| File.realpath(line.strip) }.uniq.sort
      expected = [
        "test/controllers/boards_controller_test.rb",
        "test/controllers/concerns/authentication_test.rb"
      ].map { |path| File.realpath(File.join(proj, path)) }
      assert_equal expected, recorded
    end
  end

  # --- a typed flag beats the config file, whatever the file holds (#103) ---

  # Runs Mutineer::CLI.start in-process inside `proj` and returns the Config it
  # would have run, without running it.
  def config_resolved_by_cli(proj, *argv)
    captured = nil
    cli = Mutineer::CLI.singleton_class
    original = Mutineer::CLI.method(:run)
    cli.send(:define_method, :run) { |config| captured = config }
    begin
      Dir.chdir(proj) { Mutineer::CLI.start(argv) }
    ensure
      cli.send(:define_method, :run, original)
    end
    captured
  end

  def test_typed_rails_beats_config_file_rails_false
    Dir.mktmpdir("mutineer-proj") do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "rails: false\n")
      src = File.join(FIXTURES, "boot", "widget.rb")
      # rails on means boot mode, whose own check fires; rails off would instead
      # report that no test was found by convention.
      _, err, status = mutineer("run", src, "--rails", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "--boot/--rails requires at least one --test file"
    end
  end

  def test_typed_verbose_and_debug_beat_config_file_verbose_false
    Dir.mktmpdir("mutineer-proj") do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "verbose: false\n")
      %w[--verbose --debug].each do |flag|
        assert config_resolved_by_cli(proj, "run", "x.rb", flag).verbose, flag
      end
      refute config_resolved_by_cli(proj, "run", "x.rb").verbose
    end
  end

  def rspec_project
    with_autopair_project do |proj|
      File.write(File.join(proj, "test", "calc_test.rb"), <<~RUBY)
        require_relative "../lib/calc"

        RSpec.describe Calc do
          it "adds" do
            expect(Calc.new.add(2, 3)).to eq(5)
          end
        end
      RUBY
      yield proj
    end
  end

  # An RSpec file that autopair finds under test/calc_test.rb looks like minitest
  # by name. The file's framework: rspec must survive autopair's re-detection;
  # the minitest runner cannot even load this file.
  def test_config_file_framework_survives_autopair
    rspec_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "framework: rspec\n")
      config = config_resolved_by_cli(proj, "run", "lib/calc.rb")
      Mutineer::CLI.autopair!(config)
      assert_equal "rspec", config.framework
      assert_equal ["test/calc_test.rb"], config.tests

      out, err, status = mutineer("run", "lib/calc.rb", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      summary = JSON.parse(out)["summary"]
      assert_equal 1, summary["killed"], "the RSpec runner must have run the spec"
    end
  end

  def test_cli_framework_beats_config_file_framework
    rspec_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "framework: minitest\n")
      out, err, status = mutineer("run", "lib/calc.rb", "--framework", "rspec", "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal 1, JSON.parse(out)["summary"]["killed"]
    end
  end

  def test_framework_is_detected_from_names_when_nobody_wrote_one
    with_autopair_project do |proj|
      config = config_resolved_by_cli(proj, "run", "lib/calc.rb")
      Mutineer::CLI.autopair!(config)
      assert_equal "minitest", config.framework
      refute config.explicit?(:framework)
      FileUtils.mkdir_p(File.join(proj, "spec"))
      FileUtils.mv(File.join(proj, "test", "calc_test.rb"), File.join(proj, "spec", "calc_spec.rb"))
      config = config_resolved_by_cli(proj, "run", "lib/calc.rb")
      Mutineer::CLI.autopair!(config)
      assert_equal "rspec", config.framework
    end
  end

  # --- #13 baseline gating, end to end through bin/mutineer -----------------

  # A bad/missing baseline path is a usage error (exit 2), like every other path.
  def test_bad_baseline_path_exits_two
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--baseline", "/no/such.json")
    assert_equal 2, status.exitstatus
    assert_includes err, "mutineer:"
  end

  def test_dry_run_allows_output_same_file_as_baseline_without_writing_it
    with_project do |proj|
      baseline = File.join(proj, "base.json")
      before = JSON.generate("schema_version" => "1.8", "survivors" => [])
      File.write(baseline, before)
      File.write(File.join(proj, ".mutineer.yml"), "baseline: base.json\n")

      [[], ["--baseline", "base.json"]].each do |flags|
        out, err, status = mutineer("run", "calculator.rb", "--dry-run",
                                   "--output", "base.json", *flags, chdir: proj)
        assert_equal 0, status.exitstatus, err
        assert_includes out, "mutations (dry run, not executed)"
        assert_equal before, File.read(baseline)
      end
    end
  end

  # #362 writes --output on JSON dry runs, so the same-file guard must fire (#281).
  def test_json_dry_run_rejects_output_same_file_as_baseline
    with_project do |proj|
      baseline = File.join(proj, "base.json")
      before = JSON.generate("schema_version" => "1.8", "survivors" => [])
      File.write(baseline, before)
      File.symlink("base.json", File.join(proj, "link.json"))

      [[], ["--baseline", "base.json"]].each do |flags|
        File.write(File.join(proj, ".mutineer.yml"), "baseline: base.json\n") if flags.empty?
        File.write(File.join(proj, ".mutineer.yml"), "threshold: 0\n") unless flags.empty?

        %w[base.json link.json].each do |output|
          _, err, status = mutineer(
            "run", "calculator.rb", "--dry-run", "--format", "json",
            "--output", output, *flags, chdir: proj
          )
          assert_equal 2, status.exitstatus, "flags=#{flags.inspect} output=#{output}"
          assert_includes err, "are the same file"
          assert_equal before, File.read(baseline)
        end
      end
    end
  end

  # Non-JSON dry runs ignore --output; a missing parent must not exit 2 first.
  def test_human_dry_run_ignores_output_with_missing_parent
    with_project do |proj|
      out, err, status = mutineer(
        "run", "calculator.rb", "--dry-run",
        "--output", "missing-parent/dry.json", chdir: proj
      )
      assert_equal 0, status.exitstatus, err
      assert_includes out, "mutations (dry run, not executed)"
      assert_includes err, "has no effect with --dry-run"
      refute_path_exists File.join(proj, "missing-parent")
    end
  end

  # #281: --output naming the baseline file (directly or via a link) is a
  # usage error, so a failing run cannot replace its own baseline.
  def test_output_same_file_as_baseline_exits_two
    with_project do |proj|
      _, _, s1 = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                          "--format", "json", "--output", "base.json", chdir: proj)
      assert_equal 0, s1.exitstatus
      before = File.read(File.join(proj, "base.json"))
      marker = File.join(proj, "tests-loaded")
      File.open(File.join(proj, "calculator_weak_test.rb"), "a") do |file|
        file.puts "File.write(#{marker.dump}, 'loaded')"
      end
      File.symlink("base.json", File.join(proj, "link.json"))
      File.link(File.join(proj, "base.json"), File.join(proj, "hardlink.json"))
      %w[base.json ./base.json link.json hardlink.json nosuch/../base.json].each do |output|
        _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                                  "--baseline", "base.json", "--output", output, chdir: proj)
        assert_equal 2, status.exitstatus, output
        assert_includes err, "--output and --baseline are the same file"
        refute_path_exists marker, "same-file rejection must happen before tests load (#{output})"
      end
      # A baseline from .mutineer.yml is named as such.
      File.write(File.join(proj, ".mutineer.yml"), "baseline: base.json\n")
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                                "--output", "base.json", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "--output and baseline in .mutineer.yml are the same file"
      refute_path_exists marker, "a configured baseline must be checked before tests load"
      # A separate report path runs the tests without replacing the baseline.
      _, err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                                "--baseline", "base.json", "--format", "json", "--output", "pr.json", chdir: proj)
      assert_equal 1, status.exitstatus, err
      assert_path_exists marker, "the marker must detect a run that loads the tests"
      assert_equal before, File.read(File.join(proj, "base.json"))
    end
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

  # The [mutineer] regenerate-baseline warnings in a stderr capture.
  def baseline_warnings(err)
    err.lines.grep(/\A\[mutineer\] the baseline/)
  end

  # Rewrites a --format json report as 1.2.0 wrote it: no summary.id_format, and
  # each survivor stored under its old-format id (no file path in the hash).
  def downgrade_baseline(proj, path)
    config = Mutineer::Config.new(sources: [File.join(proj, "calculator.rb")], project_root: proj)
    id_map = Mutineer::JobPlan.collect_jobs(config, Mutineer::MutatorRegistry.resolve(%w[arithmetic])).last[:id_map]
    doc = JSON.parse(File.read(path))
    doc["summary"].delete("id_format")
    doc["survivors"].each { |h| h["id"] = id_map.fetch(h["id"]) }
    File.write(path, JSON.generate(doc))
  end

  # #126 AE3 end to end, on the in-process and the external (--test-command)
  # backend: a baseline in the old id format gives zero new and zero fixed
  # survivors, one warning, and legacy_id_matches.baseline in the report. The
  # same baseline in the new format gives no warning.
  def test_old_format_baseline_matches_on_every_backend
    [[], ["--test-command", "true %{files}"]].each do |backend|
      with_project do |proj|
        run = ->(*extra) do
          mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb", *backend,
                   "--operators", "arithmetic", "--jobs", "1", "--format", "json", *extra, chdir: proj)
        end
        _, err, first = run.("--output", "base.json")
        assert_equal 0, first.exitstatus, err
        survived = JSON.parse(File.read(File.join(proj, "base.json")))["survivors"].size
        refute_equal 0, survived

        out, err, status = run.("--baseline", "base.json")
        assert_equal 0, status.exitstatus, err
        assert_empty baseline_warnings(err)
        assert_equal({ "ignore" => 0, "baseline" => 0 }, JSON.parse(out)["summary"]["legacy_id_matches"])

        downgrade_baseline(proj, File.join(proj, "base.json"))
        out, err, status = run.("--baseline", "base.json")
        assert_equal 0, status.exitstatus, err
        doc = JSON.parse(out)
        assert_empty doc["baseline"]["new_survivors"], "backend #{backend.inspect}"
        assert_empty doc["baseline"]["fixed_survivors"], "backend #{backend.inspect}"
        assert_equal({ "ignore" => 0, "baseline" => survived }, doc["summary"]["legacy_id_matches"])
        warnings = baseline_warnings(err)
        assert_equal 1, warnings.size, err
        assert_match(/old id format/, warnings.first)
        assert_match(/old ids and files/, warnings.first)
        assert_match(/--format json/, warnings.first)
        assert_match(/every gate/, warnings.first)
      end
    end
  end

  def test_test_helper_require_needs_no_rubyopt
    Dir.mktmpdir("mutineer-helper") do |proj|
      write = ->(path, body) { FileUtils.mkdir_p(File.dirname(File.join(proj, path))); File.write(File.join(proj, path), body) }
      write.("lib/calc.rb", "class Calc\n  def add(a, b) = a + b\nend\n")
      write.("test/test_helper.rb", "require 'minitest/autorun'\nrequire 'calc'\n")
      write.("test/calc_test.rb", "require 'test_helper'\n" \
                                  "class CalcTest < Minitest::Test\n  def test_add = assert_equal(3, Calc.new.add(1, 2))\nend\n")
      run = -> { mutineer("run", "lib/calc.rb", "--test", "test/calc_test.rb", "--format", "json", chdir: proj) }

      out, _err, status = run.call
      assert_equal 0, status.exitstatus
      assert_equal 100.0, JSON.parse(out).dig("summary", "score")

      Dir.mktmpdir("mutineer-helper-copy") do |copy|
        FileUtils.cp_r("#{proj}/.", copy)
        # A capture would drop this marker, so it survives only on a cache hit.
        cache = File.join(copy, ".mutineer/coverage.json")
        File.write(cache, JSON.parse(File.read(cache)).tap { |c| c["map"]["lib/calc.rb:99"] = ["test/calc_test.rb"] }.to_json)
        _out, _err, status = mutineer("run", "lib/calc.rb", "--test", "test/calc_test.rb", chdir: copy)
        assert_equal 0, status.exitstatus
        assert JSON.parse(File.read(cache))["map"].key?("lib/calc.rb:99"), "the cache must hit from another checkout"
      end

      write.("test/calc_test.rb", "require 'missing_helper'\n")
      _out, err, status = run.call
      assert_equal 1, status.exitstatus
      assert_match(/no test recorded coverage/, err)
      assert_match(/missing_helper/, err)
    end
  end

  # Both helper roots hold a check.rb; only test/a/check.rb asserts. A mutant
  # run that reverses the capture's load path order loads the empty one.
  def test_mutant_runs_keep_the_capture_load_path_order
    Dir.mktmpdir("mutineer-order") do |proj|
      write = ->(path, body) { FileUtils.mkdir_p(File.dirname(File.join(proj, path))); File.write(File.join(proj, path), body) }
      write.("lib/calc.rb", "class Calc\n  def add(a, b) = a + b\nend\n")
      %w[a b].each { |d| write.("test/#{d}/test_helper.rb", "require 'minitest/autorun'\n") }
      write.("test/a/check.rb", "module Check\n  def check = assert_equal(3, Calc.new.add(1, 2))\nend\n")
      write.("test/b/check.rb", "module Check\n  def check = pass\nend\n")
      write.("test/a/calc_test.rb", "require 'test_helper'\nrequire 'calc'\nrequire 'check'\n" \
                                    "class CalcTest < Minitest::Test\n  include Check\n  def test_add = check\nend\n")
      write.("test/b/other_test.rb", "require 'test_helper'\nclass OtherTest < Minitest::Test\n  def test_ok = pass\nend\n")

      out, _err, status = mutineer("run", "lib/calc.rb", "--test", "test/a/calc_test.rb", "--test", "test/b/other_test.rb",
                                   "--format", "json", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_equal 100.0, JSON.parse(out).dig("summary", "score")
    end
  end

  def test_help_documents_migrate
    out, _, status = mutineer("--help")
    assert_equal 0, status.exitstatus
    assert_includes out, "migrate [options] <source...>"
    assert_includes out, "matches no mutant"
    assert_includes out, "exits 1 for a miss"
    assert_includes out, "run warns and still exits 0"
  end

  def test_unmatched_ignore_warning_has_the_full_text
    _, err = capture_io { Mutineer::CLI.warn_unmatched_ignores(%w[0123456789ab]) }
    assert_equal "[mutineer] ignore entry 0123456789ab matched no mutant in this run's sources and operators. " \
                 "If those cover its code, the entry is stale: remove it.\n",
                 err
  end

  def test_old_ignore_warning_has_the_full_text
    matches = { "aaaaaaaaaaaa" => [{ id: "bbbbbbbbbbbb", file: "a.rb", subject: "A#m" }] }
    _, err = capture_io { Mutineer::CLI.warn_legacy_ignore_matches(matches) }
    assert_equal "[mutineer] ignore entry aaaaaaaaaaaa uses the old id format, which did not include the " \
                 "file path. It matched these new ids: bbbbbbbbbbbb (a.rb, A#m). This list covers only mutants in " \
                 "this run's sources and operators; a run over every source gives the complete " \
                 "replacement. Replace aaaaaaaaaaaa with the new ids in your ignore list. To update the file, " \
                 "run `mutineer migrate`. #{Mutineer::BECOMES_ERROR_IN_2_0}.\n",
                 err
  end

  def test_over_match_ignore_warning_has_the_full_text
    matches = {
      "aaaaaaaaaaaa" => [
        { id: "bbbbbbbbbbbb", file: "a.rb", subject: "A#m" },
        { id: "cccccccccccc", file: "b.rb", subject: "A#m" }
      ]
    }
    _, err = capture_io { Mutineer::CLI.warn_legacy_ignore_matches(matches) }
    assert_equal "[mutineer] ignore entry aaaaaaaaaaaa uses the old id format, which did not include the " \
                 "file path. It matched these new ids: bbbbbbbbbbbb (a.rb, A#m), cccccccccccc (b.rb, A#m). " \
                 "This list covers only mutants in this run's sources and operators; a run over every source " \
                 "gives the complete replacement. aaaaaaaaaaaa over-matched: the old format could not tell these " \
                 "mutants apart. Replace aaaaaaaaaaaa and keep only the ids for the mutant you meant to ignore, " \
                 "not all of them. To update the file, run `mutineer migrate`. #{Mutineer::BECOMES_ERROR_IN_2_0}.\n",
                 err
  end

  def test_old_baseline_warning_has_the_full_text
    _, err = capture_io { Mutineer::CLI.warn_legacy_baseline }
    assert_equal "[mutineer] the baseline uses the old id format, which did not include the file " \
                 "path, so survivors were matched on their old ids and files. Please generate a new " \
                 "baseline with `--format json`, but only after every gate that reads it runs this " \
                 "mutineer version or later. #{Mutineer::BECOMES_ERROR_IN_2_0}.\n",
                 err
    assert_includes err, "generate a new baseline with `--format json`"
  end

  def test_migrate_rewrites_old_ids_and_keeps_comments_and_key_order
    with_project do |proj|
      pairs = arithmetic_id_pairs(proj)
      (old1, new1), (old2, new2) = pairs
      path = File.join(proj, ".mutineer.yml")
      File.write(path, <<~YML)
        # project
        threshold: 0
        ignore:
          # kept
          - #{old1} # add
          - #{old2}
        operators:
          - arithmetic
      YML
      out, err, status = mutineer("migrate", "calculator.rb", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal <<~YML, File.read(path)
        # project
        threshold: 0
        ignore:
          # kept
          - #{new1} # add
          - #{new2}
        operators:
          - arithmetic
      YML
      assert_equal ["[mutineer] #{old1} -> #{new1}", "[mutineer] #{old2} -> #{new2}"], out.lines.map(&:chomp)
    end
  end

  # Plans 003 and 007 meet here: an ignore: mapping keeps its reason when
  # migrate rewrites the old id inside it.
  def test_migrate_rewrites_an_old_id_inside_a_mapping_entry_and_keeps_its_reason
    with_project do |proj|
      (old1, new1), (old2, new2) = arithmetic_id_pairs(proj)
      path = File.join(proj, ".mutineer.yml")
      File.write(path, <<~YML)
        ignore:
          - id: #{old1}
            reason: same value either way
          - { id: #{old2}, reason: "inline form" }
        operators:
          - arithmetic
      YML
      _, err, status = mutineer("migrate", "calculator.rb", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal <<~YML, File.read(path)
        ignore:
          - id: #{new1}
            reason: same value either way
          - { id: #{new2}, reason: "inline form" }
        operators:
          - arithmetic
      YML
    end
  end

  def test_migrate_dry_run_prints_changes_and_writes_nothing
    with_project do |proj|
      pairs = arithmetic_id_pairs(proj)
      (old1, new1), (old2, new2) = pairs
      path = File.join(proj, ".mutineer.yml")
      original = "ignore:\n  - #{old1}\n  - #{old2}\noperators:\n  - arithmetic\n"
      File.write(path, original)
      out, err, status = mutineer("migrate", "--dry-run", "calculator.rb", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal original, File.read(path)
      assert_includes out, "[mutineer] #{old1} -> #{new1}"
      assert_includes out, "[mutineer] #{old2} -> #{new2}"
      assert_includes err, "dry run"
    end
  end

  def test_migrate_reports_an_unmapped_id_and_exits_1
    with_project do |proj|
      old1, new1 = arithmetic_id_pairs(proj).first
      path = File.join(proj, ".mutineer.yml")
      File.write(path, "ignore:\n  - #{old1}\n  - 0123456789ab # gone\noperators:\n  - arithmetic\n")
      out, err, status = mutineer("migrate", "calculator.rb", chdir: proj)
      assert_equal 1, status.exitstatus
      assert_includes out, "[mutineer] #{old1} -> #{new1}"
      assert_includes err, "0123456789ab"
      assert_includes err, "left in place"
      assert_equal "ignore:\n  - #{new1}\n  - 0123456789ab # gone\noperators:\n  - arithmetic\n", File.read(path)
    end
  end

  def test_migrate_of_an_already_migrated_file_changes_nothing
    with_project do |proj|
      pairs = arithmetic_id_pairs(proj)
      (_old1, new1), (_old2, new2) = pairs
      path = File.join(proj, ".mutineer.yml")
      body = "ignore:\n  - #{new1}\n  - #{new2}\noperators:\n  - arithmetic\n"
      File.write(path, body)
      2.times do
        out, err, status = mutineer("migrate", "calculator.rb", chdir: proj)
        assert_equal 0, status.exitstatus, err
        assert_equal "", out
        assert_equal body, File.read(path)
      end
    end
  end

  def test_migrate_then_run_ignores_the_same_mutants_without_a_legacy_warning
    with_project do |proj|
      old1, new1 = arithmetic_id_pairs(proj).first
      File.write(File.join(proj, ".mutineer.yml"), "ignore:\n  - #{old1}\noperators:\n  - arithmetic\n")
      before, err, status = ignored_ids(proj)
      assert_equal 0, status.exitstatus, err
      assert_equal [new1], before
      refute_empty legacy_warnings(err)
      assert_includes err, "mutineer migrate"
      assert_includes err, Mutineer::BECOMES_ERROR_IN_2_0

      _out, err, status = mutineer("migrate", "calculator.rb", chdir: proj)
      assert_equal 0, status.exitstatus, err

      after, err, status = ignored_ids(proj)
      assert_equal 0, status.exitstatus, err
      assert_equal before, after
      assert_empty legacy_warnings(err)
    end
  end

  def test_migrate_without_a_config_file_exits_2
    Dir.mktmpdir("mutineer-migrate") do |proj|
      File.write(File.join(proj, "a.rb"), "def f(a) = a + 1\n")
      _, err, status = mutineer("migrate", "a.rb", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, ".mutineer.yml"
    end
  end

  def test_migrate_without_sources_exits_2
    with_project do |proj|
      File.write(File.join(proj, ".mutineer.yml"), "threshold: 0\n")
      _, err, status = mutineer("migrate", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "at least one source"
    end
  end

  # A block scalar can hold an ignore id. The command must say so and must
  # not leave the user thinking the file was migrated.
  def test_migrate_rejects_a_block_scalar_and_keeps_the_file
    Dir.mktmpdir("mutineer-migrate") do |proj|
      body = "ignore: |\n  aaaaaaaaaaaa\n"
      File.write(File.join(proj, ".mutineer.yml"), body)
      File.write(File.join(proj, "a.rb"), "def f(a) = a + 1\n")
      _, err, status = mutineer("migrate", "a.rb", chdir: proj)
      assert_equal 2, status.exitstatus
      assert_includes err, "block scalar"
      refute_match(/\.rb:\d+:in /, err)
      assert_equal body, File.read(File.join(proj, ".mutineer.yml"))
    end
  end

  def ignored_ids(proj)
    out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                "--operators", "arithmetic", "--jobs", "1", "--format", "json",
                                chdir: proj)
    [JSON.parse(out).fetch("ignored").map { |row| row.fetch("id") }.sort, err, status]
  end
  # init is a command. A bad flag is a usage error, not an unknown command.
  def test_init_flag_is_usage_not_an_unknown_command
    Dir.mktmpdir("mutineer-init-cli") do |dir|
      _out, err, status = mutineer("init", "--nope", chdir: dir)
      assert_equal 2, status.exitstatus
      refute_includes err, "unknown command"
      assert_includes err, "invalid option"
      refute File.exist?(File.join(dir, ".mutineer.yml"))
    end
  end

  # #394: `config KEY` prints what `run` would use (flag > .mutineer.yml >
  # default), so the GitHub Action can ask instead of copying these rules.
  def test_config_prints_cache_dir_by_precedence
    Dir.mktmpdir("mutineer-config") do |dir|
      out, err, status = mutineer("config", "cache_dir", chdir: dir)
      assert_equal [0, ".mutineer\n"], [status.exitstatus, out], err

      File.write(File.join(dir, ".mutineer.yml"), "cache_dir: ycache\n")
      assert_equal "ycache\n", mutineer("config", "cache_dir", chdir: dir).first
      # A short form the option parser accepts, and a source argument, as a run passes them.
      out, err, status = mutineer("config", "cache_dir", "lib/a.rb", "--cac=zcache", chdir: dir)
      assert_equal [0, "zcache\n"], [status.exitstatus, out], err
      assert_equal %w[.mutineer.yml], Dir.children(dir), "config must not create the cache folder"
    end
  end

  def test_config_prints_the_last_baseline_flag_else_the_file_else_nothing
    Dir.mktmpdir("mutineer-config") do |dir|
      out, err, status = mutineer("config", "baseline", chdir: dir)
      assert_equal [0, ""], [status.exitstatus, out], err

      File.write(File.join(dir, ".mutineer.yml"), "baseline: file.json\n")
      assert_equal "file.json\n", mutineer("config", "baseline", chdir: dir).first
      out, = mutineer("config", "baseline", "--baseline", "a.json", "--base", "b.json", chdir: dir)
      assert_equal "b.json\n", out
    end
  end

  # Qodo: a value that ends in a newline keeps it; the CLI adds exactly one
  # more, so the Action can strip that one and see the real path.
  def test_config_ends_a_value_with_exactly_one_newline
    Dir.mktmpdir("mutineer-config") do |dir|
      File.write(File.join(dir, ".mutineer.yml"), %(baseline: "b.json\\n"\n))
      assert_equal "b.json\n\n", mutineer("config", "baseline", chdir: dir).first
    end
  end

  def test_config_with_an_unknown_or_missing_key_is_a_usage_error
    [%w[config threshold], %w[config]].each do |args|
      out, err, status = mutineer(*args)
      assert_equal 2, status.exitstatus, args.inspect
      assert_empty out
      assert_includes err, "cache_dir, baseline"
      refute_includes err, "unknown command"
    end
  end
end
