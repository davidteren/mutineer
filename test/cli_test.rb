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
  # The [mutineer] old-format ignore warnings in a stderr capture.
  def legacy_warnings(err)
    err.lines.grep(/\A\[mutineer\] ignore entry/)
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
      assert_includes err, "repeat it for each test file"
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
      assert_equal "1.7", doc["schema_version"]
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
    end
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
      assert_equal "1.7", doc["schema_version"]
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
end
