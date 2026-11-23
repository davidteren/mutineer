# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
# Pre-require so the runner's forked child does not reload the original fixture
# over the mutated one (same R5/KTD4 rationale as runner_test.rb).
require_relative "fixtures/calculator"

class CoverageMapTest < Minitest::Test
  ROOT        = File.expand_path("..", __dir__)
  CALC        = File.expand_path("fixtures/calculator.rb", __dir__)
  STRONG_TEST = File.expand_path("fixtures/calculator_strong_test.rb", __dir__)
  WEAK_TEST   = File.expand_path("fixtures/calculator_weak_test.rb", __dir__)
  # Wraps each assertion in capture_subprocess_io, which reopens $stdout.
  SUBPROCESS_IO_TEST = File.expand_path("fixtures/calculator_subprocess_io_test.rb", __dir__)
  # Leaves a spawned and a forked process running for 60s after its test.
  BACKGROUND_PROCESS_TEST = File.expand_path("fixtures/calculator_background_process_test.rb", __dir__)
  # Leaves $stdout as a StringIO, at load time and inside a test.
  STDOUT_SWAP_TEST = File.expand_path("fixtures/calculator_stdout_swap_test.rb", __dir__)
  # Prints from the top level of the file, before any test runs.
  LOAD_TIME_PUTS_TEST = File.expand_path("fixtures/calculator_load_time_puts_test.rb", __dir__)
  RSPEC_LOAD_TIME_PUTS_SPEC = File.expand_path("fixtures/rspec/calculator_load_time_puts_spec.rb", __dir__)
  # A source file that prints when it loads.
  RSPEC_LOAD_TIME_BANNER = File.expand_path("fixtures/rspec/load_time_banner.rb", __dir__)
  RSPEC_CALC = File.expand_path("fixtures/rspec/calculator.rb", __dir__)
  RSPEC_STDOUT_SWAP_SPEC = File.expand_path("fixtures/rspec/calculator_stdout_swap_spec.rb", __dir__)
  # Wraps each expectation in to_stdout_from_any_process, which reopens $stdout.
  RSPEC_SUBPROCESS_IO_SPEC = File.expand_path("fixtures/rspec/calculator_subprocess_io_spec.rb", __dir__)
  # Exercises only #add, so #modulo's line is uncovered (the M4 strong suite
  # now covers every method, so it can no longer demonstrate no-coverage).
  ADD_ONLY_TEST = File.expand_path("fixtures/calculator_add_only_test.rb", __dir__)

  def build(test_paths, cache_dir: Dir.mktmpdir("mutineer-cache"))
    Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: test_paths,
      cache_dir: cache_dir, project_root: ROOT
    ).build_or_load
  end

  # `add`'s body `a + b` is line 5; `modulo`'s body `a % b` is line 21. Derive
  # the line numbers from content so the test survives fixture edits.
  def line_of(snippet)
    File.read(CALC)[0...File.read(CALC).index(snippet)].count("\n") + 1
  end

  # --- Phase A + inversion -------------------------------------------------

  def test_covered_line_maps_to_covering_test_file
    map = build([STRONG_TEST])
    assert_equal ["test/fixtures/calculator_strong_test.rb"],
                 map.tests_for(CALC, line_of("a + b"))
  end

  def test_capture_load_error_hides_the_password_and_keeps_verbose_causes
    Dir.mktmpdir("mutineer-redaction") do |dir|
      test = File.join(dir, "boom_test.rb")
      File.write(test, <<~RUBY)
        begin
          raise "database postgres://u:s3cret@host/db unavailable"
        rescue RuntimeError
          raise "outer load failure"
        end
      RUBY
      map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [test], project_root: dir, verbose: true)
      status = nil

      _, err = capture_subprocess_io { status, = map.send(:spawn_script, map.send(:subprocess_script, test)) }

      assert_equal 1, status.exitstatus
      assert_includes err, "[mutineer] load failed: RuntimeError: outer load failure"
      assert_includes err, "caused by: RuntimeError: database postgres://u:[REDACTED]@host/db unavailable"
      refute_includes err, "s3cret"
    end
  end

  def test_rspec_clean_check_load_error_hides_the_password_and_keeps_verbose_causes
    Dir.mktmpdir("mutineer-redaction") do |dir|
      preload = File.join(dir, "boot.rb")
      File.write(preload, <<~RUBY)
        begin
          raise "database postgres://u:s3cret@host/db unavailable"
        rescue RuntimeError
          raise "outer load failure"
        end
      RUBY
      map = Mutineer::CoverageMap.new(source_paths: [preload], test_paths: [], project_root: dir,
                                      framework: "rspec", verbose: true)
      status = nil

      _, err = capture_subprocess_io do
        status, = map.send(:spawn_script, map.send(:clean_check_script, []), result: true)
      end

      assert_equal 1, status.exitstatus
      assert_includes err, "[mutineer] load failed: RuntimeError: outer load failure"
      assert_includes err, "caused by: RuntimeError: database postgres://u:[REDACTED]@host/db unavailable"
      refute_includes err, "s3cret"
    end
  end

  def test_rspec_clean_check_failure_report_hides_the_password
    Dir.mktmpdir("mutineer-redaction") do |dir|
      spec = File.join(dir, "failing_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.describe "database" do
          it("connects") { raise "database postgres://u:s3cret@host/db unavailable" }
        end
      RUBY
      map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [spec], project_root: dir, framework: "rspec")
      status = line = nil

      capture_subprocess_io do
        status, line = map.send(:spawn_script, map.send(:clean_check_script, [spec]), result: true)
      end

      assert_equal 1, status.exitstatus
      report = JSON.parse(line).fetch("failure_report")
      assert_includes report, "database postgres://u:[REDACTED]@host/db unavailable"
      refute_includes report, "s3cret"
    end
  end

  # A child that exits 0 without a valid result JSON must not pass the clean check.
  def test_subprocess_clean_pass_rejects_exit_zero_without_result_json
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT)
    status = Object.new
    def status.success? = true
    def status.nil? = false
    map.define_singleton_method(:spawn_script) { |*| [status, "not-json"] }
    ok, = map.send(:subprocess_clean_pass?, [])
    refute ok, "exit 0 with no JSON result must fail closed"
  end

  # Progress dots before Failures: must not consume the capped detail (#360).
  def test_truncate_clean_detail_starts_at_failures_section
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT)
    limit = Mutineer::CoverageMap::CLEAN_FAILURE_DETAIL_LIMIT
    dots = "." * (limit + 50)
    text = "#{dots}\n\nFailures:\n\n  1) example fails\n     expected: 2\n          got: 1\n"
    out = map.send(:truncate_clean_detail, text)
    assert_operator out, :start_with?, "Failures:"
    assert_includes out, "example fails"
    assert_includes out, "got: 1"
    refute_includes out, dots[0, 20]
  end

  # An earlier Minitest Error: must win over a later Failure: (#360).
  def test_truncate_clean_detail_keeps_an_error_before_a_failure
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT)
    limit = Mutineer::CoverageMap::CLEAN_FAILURE_DETAIL_LIMIT
    noise = "x" * (limit + 20)
    text = "#{noise}\n\n  1) Error:\nDbTest#test_connect:\nRuntimeError: boom\n\n  2) Failure:\nCalcTest#test_add:\nExpected: 1\n  Actual: 2\n"
    out = map.send(:truncate_clean_detail, text)
    assert_match(/\A\s*1\) Error:/, out)
    assert_includes out, "DbTest#test_connect"
    assert_includes out, "RuntimeError: boom"
  end

  # A bare Error: inside RSpec's Failure/Error: must not cut the load header (#360).
  def test_truncate_clean_detail_keeps_rspec_load_error_header
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT)
    limit = Mutineer::CoverageMap::CLEAN_FAILURE_DETAIL_LIMIT
    noise = "." * (limit + 20)
    text = "#{noise}\n\nAn error occurred while loading ./calc_spec.rb.\nFailure/Error: raise \"boom\"\n\nRuntimeError:\n  boom\n"
    out = map.send(:truncate_clean_detail, text)
    assert_operator out, :start_with?, "An error occurred while loading ./calc_spec.rb."
    assert_includes out, "Failure/Error:"
    refute_match(/\AError:/, out)
  end

  # after(:suite) / after(:context) use the same "An error occurred" header (#360).
  def test_truncate_clean_detail_keeps_rspec_suite_hook_error
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT)
    limit = Mutineer::CoverageMap::CLEAN_FAILURE_DETAIL_LIMIT
    noise = "." * (limit + 20)
    text = "#{noise}\n\nAn error occurred in an `after(:suite)` hook.\nFailure/Error: raise \"cleanup failed\"\n\nRuntimeError:\n  cleanup failed\n"
    out = map.send(:truncate_clean_detail, text)
    assert_operator out, :start_with?, "An error occurred in an `after(:suite)` hook."
    assert_includes out, "Failure/Error:"
    assert_includes out, "cleanup failed"
  end

  # An at_exit that fails after the child wrote passed:true must still fail the
  # clean check: warm-cache scoring must not proceed on a red exit (#360).
  def test_subprocess_clean_pass_rejects_nonzero_exit_after_passed_json
    Dir.mktmpdir("mutineer-at-exit") do |dir|
      test = File.join(dir, "at_exit_fail_test.rb")
      File.write(test, <<~RUBY)
        require "minitest/test"
        class AtExitFailTest < Minitest::Test
          def test_ok
            assert true
          end
        end
        at_exit { exit 1 }
      RUBY
      map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [test], project_root: dir)
      ok = nil
      capture_subprocess_io { ok, = map.send(:subprocess_clean_pass?, [test]) }
      refute ok, "a nonzero exit after passed:true must fail the clean check"
    end
  end

  def test_fork_clean_failure_report_hides_the_password
    ensure_coverage_running
    Dir.mktmpdir("mutineer-fork-redaction") do |dir|
      test = File.join(dir, "db_fail_test.rb")
      File.write(test, <<~RUBY)
        require "minitest/test"
        class DbFailTest < Minitest::Test
          def test_connects
            raise "database postgres://u:s3cret@host/db unavailable"
          end
        end
      RUBY
      map = Mutineer::CoverageMap.new(
        source_paths: [CALC], test_paths: [test],
        cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: dir
      )
      ok = report = nil
      capture_subprocess_io { ok, report = map.send(:fork_clean_pass?, [test], nil) }
      refute ok
      assert_includes report, "database postgres://u:[REDACTED]@host/db unavailable"
      refute_includes report, "s3cret"
    end
  end

  # A fork that raises before the reporter runs still returns a redacted error (#360).
  def test_fork_clean_pass_preserves_a_redacted_exception_from_the_child
    ensure_coverage_running
    noisy = File.expand_path("fixtures/noisy_minitest_test.rb", __dir__)
    map = fork_map(noisy, verbose: false)
    ok = report = nil
    after_fork = -> { raise "database postgres://u:s3cret@host/db unavailable" }
    capture_subprocess_io { ok, report = map.send(:fork_clean_pass?, [noisy], after_fork) }
    refute ok
    assert_includes report, "RuntimeError: database postgres://u:[REDACTED]@host/db unavailable"
    refute_includes report, "s3cret"
  end

  def test_uncovered_line_returns_empty
    map = build([ADD_ONLY_TEST]) # add-only suite never calls #modulo
    assert_empty map.tests_for(CALC, line_of("a % b"))
  end

  def test_line_covered_by_two_test_files_lists_both
    map = build([STRONG_TEST, WEAK_TEST]) # both call #add
    assert_equal %w[test/fixtures/calculator_strong_test.rb test/fixtures/calculator_weak_test.rb].sort,
                 map.tests_for(CALC, line_of("a + b")).sort
  end

  def test_capture_passes_for_test_that_reopens_stdout
    map = build([SUBPROCESS_IO_TEST])
    assert_empty map.failed_clean_tests
    assert_equal ["test/fixtures/calculator_subprocess_io_test.rb"],
                 map.tests_for(CALC, line_of("a + b"))
  end

  # A process that a test leaves running inherits the child's fds. It must not
  # hold up the capture or the clean checks until it exits.
  def test_build_does_not_wait_for_processes_that_a_test_leaves_running
    pid_file = File.join(Dir.mktmpdir, "pids")
    ENV["MUTINEER_BACKGROUND_PIDS"] = pid_file
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    cache = Dir.mktmpdir("mutineer-cache")
    cold = build([BACKGROUND_PROCESS_TEST, WEAK_TEST], cache_dir: cache) # capture + combined check
    warm = build([BACKGROUND_PROCESS_TEST, WEAK_TEST], cache_dir: cache) # cached clean check
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_empty cold.failed_clean_tests
    refute warm.phase_a_ran, "second build must be a cache hit"
    assert_empty warm.failed_clean_tests
    assert_includes cold.tests_for(CALC, line_of("a + b")), "test/fixtures/calculator_background_process_test.rb"
    assert_operator elapsed, :<, 30, "build waited for the leftover processes"
  ensure
    ENV.delete("MUTINEER_BACKGROUND_PIDS")
    File.readlines(pid_file).each { |pid| Process.kill(:KILL, pid.to_i) rescue nil } if pid_file && File.exist?(pid_file) # rubocop:disable Style/RescueModifier
  end

  def test_warm_cache_clean_check_passes_for_test_that_reopens_stdout
    cache = Dir.mktmpdir("mutineer-cache")
    build([SUBPROCESS_IO_TEST], cache_dir: cache)
    warm = build([SUBPROCESS_IO_TEST], cache_dir: cache)
    refute warm.phase_a_ran, "second build must be a cache hit"
    assert_empty warm.failed_clean_tests
  end

  def test_rspec_capture_and_clean_check_pass_for_spec_that_reopens_stdout
    cache = Dir.mktmpdir("mutineer-cache")
    build = lambda do
      Mutineer::CoverageMap.new(
        source_paths: [RSPEC_CALC], test_paths: [RSPEC_SUBPROCESS_IO_SPEC],
        cache_dir: cache, project_root: ROOT, framework: "rspec"
      ).build_or_load
    end
    cold = build.call
    assert_empty cold.failed_clean_tests, "cold capture"
    assert_empty cold.failed_test_files, "cold capture"
    add_line = File.read(RSPEC_CALC).lines.index { |l| l.include?("a + b") } + 1
    assert_equal ["test/fixtures/rspec/calculator_subprocess_io_spec.rb"],
                 cold.tests_for(RSPEC_CALC, add_line)
    warm = build.call
    refute warm.phase_a_ran, "second build must be a cache hit"
    assert_empty warm.failed_clean_tests, "warm-cache clean check"
  end

  # Two or more test files also run together in one clean-check script.
  def test_combined_clean_check_passes_for_test_that_reopens_stdout
    assert_empty build([SUBPROCESS_IO_TEST, WEAK_TEST]).failed_clean_tests
  end

  def test_rspec_combined_clean_check_passes_for_spec_that_reopens_stdout
    map = Mutineer::CoverageMap.new(
      source_paths: [RSPEC_CALC],
      test_paths: [RSPEC_SUBPROCESS_IO_SPEC, File.expand_path("fixtures/rspec/calculator_weak_spec.rb", __dir__)],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, framework: "rspec"
    ).build_or_load
    assert_empty map.failed_clean_tests
  end

  def test_capture_and_clean_checks_pass_for_test_that_swaps_stdout_for_a_stringio
    cache = Dir.mktmpdir("mutineer-cache")
    cold = build([STDOUT_SWAP_TEST], cache_dir: cache)
    assert_empty cold.failed_test_files, "cold capture"
    assert_empty cold.failed_clean_tests, "cold capture"
    assert_equal ["test/fixtures/calculator_stdout_swap_test.rb"], cold.tests_for(CALC, line_of("a + b"))
    warm = build([STDOUT_SWAP_TEST], cache_dir: cache)
    refute warm.phase_a_ran, "second build must be a cache hit"
    assert_empty warm.failed_clean_tests, "warm-cache clean check"
    assert_empty build([STDOUT_SWAP_TEST, WEAK_TEST]).failed_clean_tests, "combined clean check"
  end

  def test_rspec_capture_and_clean_checks_pass_for_spec_that_swaps_stdout_for_a_stringio
    cache = Dir.mktmpdir("mutineer-cache")
    build = lambda do |specs, dir|
      Mutineer::CoverageMap.new(
        source_paths: [RSPEC_CALC], test_paths: specs,
        cache_dir: dir, project_root: ROOT, framework: "rspec"
      ).build_or_load
    end
    cold = build.call([RSPEC_STDOUT_SWAP_SPEC], cache)
    assert_empty cold.failed_test_files, "cold capture"
    assert_empty cold.failed_clean_tests, "cold capture"
    warm = build.call([RSPEC_STDOUT_SWAP_SPEC], cache)
    refute warm.phase_a_ran, "second build must be a cache hit"
    assert_empty warm.failed_clean_tests, "warm-cache clean check"
    weak = File.expand_path("fixtures/rspec/calculator_weak_spec.rb", __dir__)
    assert_empty build.call([RSPEC_STDOUT_SWAP_SPEC, weak], Dir.mktmpdir("mutineer-cache")).failed_clean_tests,
                 "combined clean check"
  end

  # Output that a test file writes at load time goes to stdout, not to the
  # channel that carries the capture result.
  def test_capture_succeeds_for_test_that_prints_at_load_time
    cache = Dir.mktmpdir("mutineer-cache")
    cold = build([LOAD_TIME_PUTS_TEST], cache_dir: cache)
    assert_empty cold.failed_test_files, "cold capture"
    assert_empty cold.failed_clean_tests, "cold capture"
    assert_equal ["test/fixtures/calculator_load_time_puts_test.rb"], cold.tests_for(CALC, line_of("a + b"))
    assert_empty build([LOAD_TIME_PUTS_TEST], cache_dir: cache).failed_clean_tests, "warm-cache clean check"
  end

  # The capture script loads sources before RSpec loads the spec, so this covers
  # a print from each phase.
  def test_rspec_capture_succeeds_for_spec_and_source_that_print_at_load_time
    map = Mutineer::CoverageMap.new(
      source_paths: [RSPEC_CALC, RSPEC_LOAD_TIME_BANNER], test_paths: [RSPEC_LOAD_TIME_PUTS_SPEC],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, framework: "rspec"
    ).build_or_load
    assert_empty map.failed_test_files
    assert_empty map.failed_clean_tests
    add_line = File.read(RSPEC_CALC).lines.index { |l| l.include?("a + b") } + 1
    assert_equal ["test/fixtures/rspec/calculator_load_time_puts_spec.rb"], map.tests_for(RSPEC_CALC, add_line)
  end

  def test_failing_test_file_is_skipped_without_aborting
    bad = File.join(Dir.mktmpdir, "broken_test.rb")
    File.write(bad, "require 'does/not/exist'\n")
    map = build([STRONG_TEST, bad])

    refute_empty map.tests_for(CALC, line_of("a + b")), "good test still recorded"
    assert_includes map.failed_test_files.map { |f| File.basename(f) }, "broken_test.rb"
  end

  # #96: an assertion failure is a red unmutated suite, not a skipped capture.
  def test_assertion_failure_is_failed_clean_not_capture_skip
    Dir.mktmpdir("mutineer-clean") do |dir|
      src  = File.join(dir, "calc.rb")
      test = File.join(dir, "calc_test.rb")
      File.write(src, "class AuditFailingCalculator\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(test, <<~RUBY)
        require "minitest/autorun"
        require_relative "calc"
        class AuditFailingCalculatorTest < Minitest::Test
          def test_add
            refute_nil AuditFailingCalculator.new.add(2, 3)
          end
          def test_unrelated
            assert_equal 1, 2
          end
        end
      RUBY
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(
          source_paths: [src], test_paths: [test],
          cache_dir: File.join(dir, "cache"), project_root: dir
        ).build_or_load
      end
      assert_includes map.failed_clean_tests, "calc_test.rb"
      assert_empty map.failed_test_files, "a red assertion is not a capture crash"
      # #360: the failing test name is kept for the SmokeCheckError line.
      detail = map.failed_clean_details["calc_test.rb"].to_s
      assert_match(/AuditFailingCalculatorTest#test_unrelated/, detail, detail)
      assert_match(/Expected: 1\s+Actual: 2/, detail, detail)
    end
  end

  # #497: Rails' Minitest plugin removes every SummaryReporter, so a report
  # built on one came back empty. Both clean-check paths must still name the
  # failing test, its error, and the first backtrace line.
  def test_clean_check_report_survives_a_plugin_that_drops_summary_reporters
    Dir.mktmpdir("mutineer-497") do |dir|
      test = File.join(dir, "red_test.rb")
      File.write(test, <<~RUBY)
        require "minitest/autorun"
        # Mirrors railties' plugin_rails_init, which rejects SummaryReporter.
        Minitest.extensions << "fake_rails" unless Minitest.extensions.include?("fake_rails")
        def Minitest.plugin_fake_rails_init(options)
          reporter.reporters.reject! { |r| r.is_a?(Minitest::SummaryReporter) }
          reporter << Minitest::SummaryReporter.new(File.open(File::NULL, "w"), options)
        end
        class RedFor497Test < Minitest::Test
          def test_boom
            raise ArgumentError, "boom 497"
          end
        end
      RUBY
      map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [test], project_root: dir)
      fork_ok, fork_detail, = map.send(:fork_clean_pass?, [test], nil)
      sub_ok, sub_detail, = map.send(:subprocess_clean_pass?, [test])
      [[fork_ok, fork_detail], [sub_ok, sub_detail]].each do |ok, detail|
        refute ok
        assert_match(/RedFor497Test#test_boom/, detail, detail)
        assert_match(/ArgumentError: boom 497/, detail, detail)
        assert_match(/red_test\.rb:\d+/, detail, detail)
      end
    end
  end

  # #497 review: the failure reporter fails closed, so a run whose summary
  # reporters a plugin dropped is still red.
  def test_minitest_failure_report_fails_closed
    report = Mutineer::MinitestFailureReport.new(StringIO.new)
    pass = Struct.new(:passed?, :skipped?).new(true, false)
    fail = Struct.new(:passed?, :skipped?).new(false, false)
    report.record(pass)
    assert_predicate report, :passed?
    report.record(fail)
    refute_predicate report, :passed?
  end

  # #96: a warm cache cannot certify a suite that now fails without a file-content
  # change (the digest still matches).
  def test_warm_cache_records_failed_clean_when_suite_turns_red
    Dir.mktmpdir("mutineer-warm-clean") do |dir|
      src    = File.join(dir, "calc.rb")
      test   = File.join(dir, "calc_test.rb")
      marker = File.join(dir, "pass_marker")
      File.write(src, "class AuditWarmCalculator\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(test, <<~RUBY)
        require "minitest/autorun"
        require_relative "calc"
        class AuditWarmCalculatorTest < Minitest::Test
          def test_add
            assert_equal 5, AuditWarmCalculator.new.add(2, 3)
          end
          def test_environment
            assert File.exist?(File.expand_path("pass_marker", __dir__)), "marker missing"
          end
        end
      RUBY
      mk = lambda do
        Mutineer::CoverageMap.new(
          source_paths: [src], test_paths: [test],
          cache_dir: File.join(dir, "cache"), project_root: dir
        ).build_or_load
      end

      File.write(marker, "ok\n")
      first = nil
      capture_subprocess_io { first = mk.call }
      assert_empty first.failed_clean_tests
      assert first.phase_a_ran

      File.unlink(marker)
      second = nil
      capture_subprocess_io { second = mk.call }
      refute second.phase_a_ran, "digest still matches — do not rebuild coverage"
      assert_includes second.failed_clean_tests, "calc_test.rb"
    end
  end

  # --- #8: fork-capture diagnostic (R1/KTD-1) ------------------------------

  # A test file whose top-level `raise` makes the forked child blow up while
  # loading it — exercising fork_capture's `rescue Exception` String path.
  def raising_test
    f = File.join(Dir.mktmpdir, "raising_test.rb")
    File.write(f, %(raise "boom from child"\n))
    f
  end

  # A boot-mode run earlier in this process leaves Coverage suspended (#228).
  def ensure_coverage_running
    case Coverage.state
    when :idle then Coverage.start(lines: true, methods: true)
    when :suspended then Coverage.resume
    end
  end

  def fork_map(test_path, verbose:)
    Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: [test_path],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, verbose: verbose
    )
  end

  def test_fork_capture_returns_string_diagnostic_for_raising_child
    ensure_coverage_running
    map = fork_map(raising_test, verbose: true)
    payload = map.send(:fork_capture, raising_test, [CALC], nil)
    assert_kind_of String, payload
    assert_match(/RuntimeError: boom from child/, payload)
  end

  # #19: a child that dies WITHOUT writing (hard crash / signal) must yield a
  # diagnostic string naming how it died — not a bare nil/"no result".
  def test_fork_capture_reports_child_death_when_no_output
    ensure_coverage_running
    killed = File.join(Dir.mktmpdir, "suicide_test.rb")
    File.write(killed, %(Process.kill("KILL", Process.pid)\n))
    map = fork_map(killed, verbose: true)
    payload = map.send(:fork_capture, killed, [CALC], nil)
    assert_kind_of String, payload, "child death must produce a diagnostic, not nil"
    assert_match(/no result/, payload)
    assert_match(/signal 9|SIGKILL/, payload)
  end

  # #19: describe_status formats exit codes and signals for capture diagnostics.
  def test_describe_status_formats_exit_and_signal
    map = fork_map(raising_test, verbose: false)
    exit_st = wait_child(fork { exit!(3) })
    assert_match(/exit status 3/, map.send(:describe_status, exit_st))
    pid = fork { sleep 5 }
    Process.kill("KILL", pid)
    _, sig_st = Process.waitpid2(pid)
    assert_match(/signal 9/, map.send(:describe_status, sig_st))
  end

  def test_build_via_fork_surfaces_real_error_under_verbose
    ensure_coverage_running
    rt = raising_test
    map = fork_map(rt, verbose: true)
    _, err = capture_subprocess_io { map.build_via_fork(after_fork: nil) }
    assert_match(/boom from child/, err)
    assert_includes map.failed_test_files.map { |f| File.basename(f) }, "raising_test.rb"
  end

  def test_build_via_fork_suppresses_error_without_verbose
    ensure_coverage_running
    rt = raising_test
    map = fork_map(rt, verbose: false)
    _, err = capture_subprocess_io { map.build_via_fork(after_fork: nil) }
    assert_match(/re-run with --verbose/, err)
    refute_match(/boom from child/, err)
    assert_includes map.failed_test_files.map { |f| File.basename(f) }, "raising_test.rb"
  end

  # --- #9: uncapturable taint rule (errored capture vs genuine gap) --------

  # The ONLY test for calculator.rb is broken, so the source gets zero coverage
  # AND its _test sibling lands in failed_test_files -> the file is tainted.
  def broken_calculator_test
    f = File.join(Dir.mktmpdir, "calculator_test.rb") # basename maps to calculator.rb
    File.write(f, "require 'does/not/exist'\n")
    f
  end

  def test_uncapturable_source_true_when_only_covering_test_errored
    map = nil
    capture_subprocess_io { map = build([broken_calculator_test]) }
    assert map.uncapturable_source?(CALC),
           "errored capture for the only test should taint the source"
  end

  def test_uncapturable_source_false_for_genuine_no_coverage
    map = build([ADD_ONLY_TEST]) # no failures; #modulo simply untested
    refute map.uncapturable_source?(CALC),
           "no failed captures -> genuine no_coverage, not uncapturable"
  end

  # End-to-end via Runner: a mutant on a zero-coverage line of a tainted source
  # is :uncapturable, not :no_coverage.
  def test_runner_returns_uncapturable_for_tainted_source
    map = nil
    capture_subprocess_io { map = build([broken_calculator_test]) }
    result = Mutineer::Runner.run(plus_mutation, source_file: CALC, coverage_map: map)
    assert_predicate result, :uncapturable?, "got #{result.status} (#{result.details})"
  end

  # --- Cache: digest, load/save, invalidation ------------------------------

  def test_cache_written_and_reused_without_rerunning_phase_a
    dir = Dir.mktmpdir("mutineer-cache")
    first = build([STRONG_TEST], cache_dir: dir)
    assert first.phase_a_ran
    assert_path_exists File.join(dir, "coverage.json")

    second = build([STRONG_TEST], cache_dir: dir)
    refute second.phase_a_ran, "digest matched — Phase A should be skipped"
    assert_equal first.tests_for(CALC, line_of("a + b")),
                 second.tests_for(CALC, line_of("a + b"))
  end

  def test_content_change_invalidates_cache_and_rebuilds
    dir = Dir.mktmpdir("mutineer-proj")
    cache = Dir.mktmpdir("mutineer-cache")
    src  = File.join(dir, "thing.rb")
    test = File.join(dir, "thing_test.rb")
    File.write(src, "class TmpThing\n  def go\n    42\n  end\nend\n")
    File.write(test, <<~RUBY)
      require "minitest/autorun"
      require_relative "thing"
      class TmpThingTest < Minitest::Test
        def test_go; assert_equal 42, TmpThing.new.go; end
      end
    RUBY

    mk = lambda do
      Mutineer::CoverageMap.new(source_paths: [src], test_paths: [test],
                              cache_dir: cache, project_root: dir).build_or_load
    end

    first = mk.call
    assert first.phase_a_ran
    refute mk.call.phase_a_ran, "unchanged files: cache hit"

    File.write(test, File.read(test).sub("test_go", "test_renamed"))
    assert mk.call.phase_a_ran, "test file changed: cache must rebuild"
  end

  SHARED = File.realpath(File.expand_path("fixtures/shared_capture", __dir__))
  SHARED_TESTS = %w[alpha_test.rb beta_test.rb].freeze

  def shared_map(sources, cache_dir, root: SHARED, **options)
    Mutineer::CoverageMap.new(source_paths: sources, test_paths: SHARED_TESTS, cache_dir: cache_dir,
                              project_root: root, boot_path: File.join(root, "boot.rb"), **options).build_via_fork
  end

  def sentinel_runs(path)
    File.readlines(path, chomp: true).map(&:split).tap { File.write(path, "") }
  end

  def test_coverage_from_runs_only_the_covering_tests_alone_and_keeps_the_subset_map
    ensure_coverage_running
    require File.join(SHARED, "boot")
    Dir.mktmpdir do |dir|
      sentinel = File.join(dir, "sentinel")
      File.write(sentinel, "")
      ENV["MUTINEER_SENTINEL"] = sentinel
      capture, shard, fresh = %w[capture shard fresh].map { |name| File.join(dir, name) }

      shared_map(%w[alpha.rb beta.rb], capture)
      assert_operator sentinel_runs(sentinel).map(&:first).uniq.size, :>=, 3, "each capture fork and the combined run"

      reused = shared_map(%w[alpha.rb], shard, coverage_from: File.join(capture, "coverage.json"))
      runs = sentinel_runs(sentinel).group_by(&:first).values.map { |run| run.map(&:last).sort }
      assert_equal [%w[alpha_test.rb]], runs,
                   "alpha_test.rb, the only test covering alpha.rb, runs alone; beta_test.rb never runs " \
                   "with a mutant, so there is no combined run (#398)"
      refute reused.phase_a_ran
      assert_path_exists File.join(shard, "coverage.json")

      expected = shared_map(%w[alpha.rb], fresh)
      refute_empty expected.map
      assert_equal expected.map, reused.map
    ensure
      ENV.delete("MUTINEER_SENTINEL")
    end
  end

  def test_coverage_from_rejects_a_capture_that_does_not_fit_the_run
    ensure_coverage_running
    edit_cache = ->(file, &change) { File.write(file, JSON.generate(JSON.parse(File.read(file)).tap(&change))) }
    cases = {
      "an unchanged project" => [->(_root, _cache) {}, nil],
      "a changed test" => [->(root, _cache) { File.write(File.join(root, "beta_test.rb"), "\n", mode: "a") },
                           /tests, --require files, boot file, load paths, framework or test seed differ/],
      "a changed source" => [->(root, _cache) { File.write(File.join(root, "alpha.rb"), "\n", mode: "a") },
                             /alpha\.rb changed since the capture/],
      "a source outside the capture" => [->(_root, _cache) {}, /not captured over beta\.rb/, %w[alpha.rb]],
      "a new owner" => [->(root, _cache) { File.write(File.join(root, "alpha_extra.rb"), "") },
                        /alpha_extra\.rb appeared since the capture/],
      "a removed owner" => [->(_root, cache) { edit_cache.(cache) { |c| c["owners"] += ["alpha_extra.rb"] } },
                            /alpha_extra\.rb disappeared since the capture/],
      "another PARALLEL_WORKERS" => [->(_root, cache) { edit_cache.(cache) { |c| c["parallel_workers"] = "4" } },
                                     /captured with PARALLEL_WORKERS="4"/],
      "a changed file the tests load" => [->(root, _cache) { File.write(File.join(root, "beta.rb"), "\n", mode: "a") },
                                          /a file its tests loaded changed/],
      "a failed capture" => [->(_root, cache) { edit_cache.(cache) { |c| c["failed_test_files"] = ["beta_test.rb"] } },
                             /capture failed for beta_test\.rb/],
      "a cache without fingerprints" => [->(_root, cache) { edit_cache.(cache) { |c| c.delete("sources") } },
                                         /no source fingerprints/],
      "a malformed owner list" => [->(_root, cache) { edit_cache.(cache) { |c| c["owners"] = [1] } },
                                   /not the shape a coverage cache saves/],
      "a malformed map" => [->(_root, cache) { edit_cache.(cache) { |c| c["map"] = { "alpha.rb:5" => "alpha_test.rb" } } },
                            /not the shape a coverage cache saves/],
      "a missing file" => [->(_root, cache) { File.delete(cache) }, /cannot be read/]
    }
    cases.each do |name, (change, error, captured)|
      Dir.mktmpdir do |root|
        FileUtils.cp(Dir[File.join(SHARED, "*.rb")], root)
        cache = File.join(root, "capture", "coverage.json")
        shared_map(captured || %w[alpha.rb beta.rb], File.dirname(cache), root: root)
        change.(root, cache)
        shard = -> { shared_map(captured ? %w[alpha.rb beta.rb] : %w[alpha.rb], File.join(root, "shard"), root: root, coverage_from: cache) }
        if error
          err = assert_raises(Mutineer::CoverageFromError, name) { shard.call }
          assert_match error, err.message, name
        else
          refute shard.call.phase_a_ran, name
        end
      end
    end
  end

  def test_coverage_from_with_one_test_still_runs_it_clean
    ensure_coverage_running
    Dir.mktmpdir do |dir|
      single = ->(cache, **options) do
        Mutineer::CoverageMap.new(source_paths: %w[alpha.rb], test_paths: %w[alpha_test.rb], project_root: SHARED,
                                  cache_dir: File.join(dir, cache), boot_path: File.join(SHARED, "boot.rb"),
                                  **options).build_via_fork
      end
      single.("capture")
      ENV["MUTINEER_FLUNK"] = "1"
      reused = single.("shard", coverage_from: File.join(dir, "capture", "coverage.json"))
      assert_equal %w[alpha_test.rb], reused.failed_clean_tests
    ensure
      ENV.delete("MUTINEER_FLUNK")
    end
  end

  def test_coverage_from_catches_a_covering_test_that_fails_only_alone
    ensure_coverage_running
    Dir.mktmpdir do |dir|
      shared_map(%w[alpha.rb beta.rb], File.join(dir, "capture"))
      ENV["MUTINEER_FLUNK_ALONE"] = "1"
      reused = shared_map(%w[alpha.rb], File.join(dir, "shard"),
                          coverage_from: File.join(dir, "capture", "coverage.json"))
      assert_equal %w[alpha_test.rb], reused.failed_clean_tests
      refute_path_exists File.join(dir, "shard", "coverage.json")
    ensure
      ENV.delete("MUTINEER_FLUNK_ALONE")
    end
  end

  def test_coverage_from_refuses_to_overwrite_the_capture_it_reads
    Dir.mktmpdir do |dir|
      err = assert_raises(Mutineer::CoverageFromError) do
        shared_map(%w[alpha.rb], dir, coverage_from: File.join(dir, "coverage.json"))
      end
      assert_match(/this run's own cache/, err.message)
    end
  end

  # #303: with LANG unset Ruby reads files as US-ASCII. A cache or a
  # --coverage-from capture with a non-ASCII path must still parse.
  def test_reads_a_non_ascii_cache_and_capture_under_an_ascii_locale
    Dir.mktmpdir do |dir|
      capture = File.join(dir, "capture.json")
      [File.join(dir, "coverage.json"), capture].each { |f| File.write(f, JSON.generate("caf\u00e9.rb" => [1])) }
      map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], cache_dir: dir, coverage_from: capture)
      with_ascii_default_external do
        assert_equal [1], map.send(:read_cache)["caf\u00e9.rb"]
        err = assert_raises(Mutineer::CoverageFromError) { map.send(:accepted_capture) }
        assert_match(/cannot be reused/, err.message, "the capture parsed, then failed the fit check")
      end
    end
  end

  # --- #398: the clean check runs only the tests a mutant can run ---------

  # Runs the block with MUTINEER_SENTINEL set, then returns each process's
  # test files, sorted, so a combined run reads as one entry.
  def sentinel_processes(dir)
    sentinel = File.join(dir, "sentinel")
    File.write(sentinel, "")
    ENV["MUTINEER_SENTINEL"] = sentinel
    yield
    sentinel_runs(sentinel).group_by(&:first).values.map { |run| run.map(&:last).sort }.sort
  ensure
    ENV.delete("MUTINEER_SENTINEL")
  end

  # The booted parent, as `--boot` loads it: beta.rb then reads
  # SharedAlpha.widen at boot, so only alpha_test.rb covers alpha.rb.
  def boot_shared
    ensure_coverage_running
    require File.join(SHARED, "boot")
  end

  def test_cache_hit_runs_only_the_covering_tests_clean
    boot_shared
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      first = nil
      err = nil
      misses = sentinel_processes(dir) { _, err = capture_io { first = shared_map(%w[alpha.rb], cache) } }
      assert first.phase_a_ran
      assert_equal [%w[alpha_test.rb], %w[beta_test.rb]], misses,
                   "a miss captures each test alone; one covering test leaves no combined run"
      assert_includes err, "[mutineer] coverage capture: the together check covers only the 1 test file that " \
                           "covers the sources; 1 other test file ran alone only."
      # #495: no separate clean check ran a test on this miss, so no seconds.
      assert_nil first.clean_check_seconds

      hit = nil
      hits = sentinel_processes(dir) { _, err = capture_io { hit = shared_map(%w[alpha.rb], cache) } }
      refute hit.phase_a_ran
      assert_equal [%w[alpha_test.rb]], hits, "beta_test.rb covers no line of alpha.rb, so it is not run"
      assert_empty hit.failed_clean_tests
      # #495: the hit's clean check ran a test, so it has seconds.
      assert_kind_of Float, hit.clean_check_seconds
      assert_operator hit.clean_check_seconds, :>, 0
      assert_includes err, "[mutineer] coverage cache hit: the clean check ran the 1 test file that covers " \
                           "the sources; 1 other test file never runs with a mutant and was not checked."
    end
  end

  def test_cache_hit_stops_on_a_covering_test_that_turns_red
    boot_shared
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      capture_io { shared_map(%w[alpha.rb], cache) }
      hit = nil
      with_env("MUTINEER_FLUNK" => "1") { capture_io { hit = shared_map(%w[alpha.rb], cache) } }
      refute hit.phase_a_ran
      assert_equal %w[alpha_test.rb], hit.failed_clean_tests
    end
  end

  # beta_test.rb is red, but it covers no line of alpha.rb, so no mutant of
  # this run can run it. A miss still stops on it (#96): capture runs every test.
  def test_cache_hit_skips_a_red_test_that_covers_no_source
    boot_shared
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      capture_io { shared_map(%w[alpha.rb], cache) }
      hit = nil
      miss = nil
      with_env("MUTINEER_FLUNK_BETA" => "1") do
        capture_io { hit = shared_map(%w[alpha.rb], cache) }
        capture_io { miss = shared_map(%w[alpha.rb], File.join(dir, "fresh")) }
      end
      refute hit.phase_a_ran
      assert_empty hit.failed_clean_tests
      assert miss.phase_a_ran
      assert_equal %w[beta_test.rb], miss.failed_clean_tests, "the test really is red"
    end
  end

  # An empty map keeps every test: the daemon then runs every test for each mutant.
  def test_cache_hit_with_an_empty_map_checks_every_test
    ensure_coverage_running
    Dir.mktmpdir do |root|
      FileUtils.cp(Dir[File.join(SHARED, "*.rb")], root)
      File.write(File.join(root, "gamma.rb"), "class SharedGamma\n  def self.triple(x)\n    x * 3\n  end\nend\n")
      cache = File.join(root, "cache")
      first = nil
      capture_io { first = shared_map(%w[gamma.rb], cache, root: root) }
      assert_empty first.map, "no test calls SharedGamma"

      hits = sentinel_processes(root) { capture_io { shared_map(%w[gamma.rb], cache, root: root) } }
      assert_equal [%w[alpha_test.rb], %w[alpha_test.rb beta_test.rb], %w[beta_test.rb]], hits
    end
  end

  # A retried capture runs its test, so the hit does not run it alone again.
  def test_cache_hit_runs_a_retried_capture_once
    boot_shared
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      capture_io { shared_map(%w[alpha.rb], cache) }
      file = File.join(cache, "coverage.json")
      File.write(file, JSON.generate(JSON.parse(File.read(file)).merge("failed_test_files" => ["alpha_test.rb"])))

      hit = nil
      hits = sentinel_processes(dir) { capture_io { hit = shared_map(%w[alpha.rb], cache) } }
      refute hit.phase_a_ran
      assert_equal [%w[alpha_test.rb]], hits
      assert_empty hit.failed_test_files
    end
  end

  # Every test a mutant can be given must be in the clean check.
  def test_every_test_a_mutant_can_run_is_in_the_clean_check
    boot_shared
    Dir.mktmpdir do |dir|
      map = nil
      capture_io { map = shared_map(%w[alpha.rb beta.rb], dir) }
      checked = map.send(:clean_check_test_paths).map { |t| map.send(:relativize, t) }
      # A mutant lives in a source, so only source keys can give it tests.
      keys = map.map.keys.select { |key| %w[alpha.rb beta.rb].include?(key.split(":").first) }
      selectable = keys.flat_map { |key| map.tests_for(*key.split(":").then { |f, l| [f, l.to_i] }) }.uniq
      refute_empty selectable
      assert_equal selectable.sort, checked.sort, "the check runs exactly the tests a mutant can be given"
    end
  end

  # Standalone capture also maps the other project files a test ran, its own
  # file too. No mutant lives there, so those keys must not pick a test.
  def test_the_clean_check_reads_only_source_keys
    map = Mutineer::CoverageMap.new(source_paths: %w[price.rb], test_paths: %w[price_test.rb mail_test.rb],
                                    project_root: Dir.pwd)
    map.instance_variable_set(:@map, { "price.rb:3" => %w[price_test.rb], "mail_test.rb:1" => %w[mail_test.rb] })
    assert_equal %w[price_test.rb], map.send(:clean_check_test_paths)

    map.instance_variable_set(:@map, { "mail_test.rb:1" => %w[mail_test.rb] })
    assert_equal %w[price_test.rb mail_test.rb], map.send(:clean_check_test_paths),
                 "no source key: every test, as for an empty map"
  end

  # --- #426: standalone load lines are not coverage of every test ---------

  # The source, the test that calls it, and a test that does not. Line numbers
  # come from the source text so the assertions follow the credit rule.
  STANDALONE_PRICE = <<~RUBY
    class StandalonePrice
      def self.called(n)
        n * 2
      end

      def self.only_at_load(n)
        n + 9
      end

      def self.both(n)
        n * 4
      end

      def self.endless(n) = n * 3

      LOADED = only_at_load(1)
      BOTH = both(1)
    end
  RUBY

  def write_standalone_price(dir)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib/price.rb"), STANDALONE_PRICE)
    FileUtils.mkdir_p(File.join(dir, "test"))
    note = 'File.write(ENV["MUTINEER_SENTINEL"], "#{Process.pid} #{File.basename(__FILE__)}\n", mode: "a") if ENV["MUTINEER_SENTINEL"]'
    File.write(File.join(dir, "test/price_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/price"
      #{note}
      class StandalonePriceTest < Minitest::Test
        def test_called; assert_equal 4, StandalonePrice.called(2); end
        def test_endless; assert_equal 6, StandalonePrice.endless(2); end
        def test_both; assert_equal 8, StandalonePrice.both(2); end
        def test_loaded; assert_equal 10, StandalonePrice::LOADED; end
      end
    RUBY
    # Not the conventional pair. It calls the endless method, so that `def`
    # line is credited from the call, not from pairing.
    File.write(File.join(dir, "test/caller_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/price"
      #{note}
      class StandaloneCallerTest < Minitest::Test
        def test_endless; assert_equal 9, StandalonePrice.endless(3); end
      end
    RUBY
    File.write(File.join(dir, "test/mail_test.rb"), <<~RUBY)
      require "minitest/autorun"
      #{note}
      class StandaloneMailTest < Minitest::Test
        def test_ok; assert_equal 1, 1; end
      end
    RUBY
  end

  def standalone_price_map(dir, cache, framework: "minitest", tests: nil)
    tests ||= if framework == "rspec"
                %w[spec/caller_spec.rb spec/price_spec.rb spec/mail_spec.rb]
              else
                %w[test/caller_test.rb test/price_test.rb test/mail_test.rb]
              end
    Mutineer::CoverageMap.new(source_paths: ["lib/price.rb"], test_paths: tests, cache_dir: cache,
                              project_root: dir, framework: framework).build_or_load
  end

  def price_line(snippet)
    STANDALONE_PRICE[0...STANDALONE_PRICE.index(snippet)].count("\n") + 1
  end

  # Class and `def` lines, and a body that runs only while the source loads,
  # belong to the paired test. A test that never calls the source does not
  # cover them, so a cache hit does not check it. A body the paired test
  # runs, including one that also ran at load, stays credited to that test.
  # An endless method stays credited because the test called it: Ruby does
  # not count that line on the call.
  def test_standalone_capture_does_not_credit_an_unrelated_test_with_load_lines
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_standalone_price(dir)
      src = File.join(dir, "lib/price.rb")
      map = nil
      err = nil
      misses = sentinel_processes(dir) { _, err = capture_io { map = standalone_price_map(dir, cache) } }

      assert map.phase_a_ran
      assert_empty map.failed_test_files
      assert_equal [%w[caller_test.rb], %w[caller_test.rb price_test.rb], %w[mail_test.rb], %w[price_test.rb]], misses,
                   "a miss captures each test, then the two that cover price.rb together"
      assert_equal %w[test/price_test.rb], map.tests_for(src, price_line("class StandalonePrice"))
      assert_equal %w[test/price_test.rb], map.tests_for(src, price_line("n + 9"))
      assert_equal %w[test/price_test.rb], map.tests_for(src, price_line("n * 2"))
      assert_equal %w[test/price_test.rb], map.tests_for(src, price_line("n * 4"))
      assert_equal %w[test/caller_test.rb test/price_test.rb], map.tests_for(src, price_line("n * 3")).sort
      assert map.ran_at_load?(src, price_line("class StandalonePrice"))
      assert map.ran_at_load?(src, price_line("n + 9")), "only_at_load ran while the class loaded"
      assert map.ran_at_load?(src, price_line("n * 4")), "both ran at load and in the test"
      refute map.ran_at_load?(src, price_line("n * 2")), "called runs only in the test"
      def_line = price_line("def self.only_at_load")
      assert map.method_ran_at_load?(src, def_line, STANDALONE_PRICE.lines[def_line - 1].index("def"))
      assert_includes err, "1 other test file ran alone only"

      hit = nil
      hits = sentinel_processes(dir) { _, err = capture_io { hit = standalone_price_map(dir, cache) } }
      refute hit.phase_a_ran
      assert_equal [%w[caller_test.rb], %w[caller_test.rb price_test.rb], %w[price_test.rb]], hits,
                   "mail_test.rb covers no line a mutant of price.rb runs"
      assert_equal map.load_lines, hit.load_lines
      assert_includes err, "1 other test file never runs with a mutant and was not checked"
    end
  end

  # No conventional pair in the run: any test may be the one that checks a
  # value built at load, so both keep the load-only line and a hit checks both.
  def test_standalone_load_lines_stay_on_every_test_when_none_pairs
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib/widget.rb"), "class StandaloneWidget\n  def self.n\n    1\n  end\nend\n")
      FileUtils.mkdir_p(File.join(dir, "test"))
      %w[a_check b_check].each do |name|
        File.write(File.join(dir, "test/#{name}_test.rb"), <<~RUBY)
          require "minitest/autorun"
          File.write(ENV["MUTINEER_SENTINEL"], "\#{Process.pid} \#{File.basename(__FILE__)}\\n", mode: "a") if ENV["MUTINEER_SENTINEL"]
          class #{name.capitalize}CheckTest < Minitest::Test
            def test_ok; assert_equal 1, 1; end
          end
        RUBY
      end
      cache = File.join(dir, "cache")
      tests = %w[test/a_check_test.rb test/b_check_test.rb]
      map = nil
      capture_io do
        map = Mutineer::CoverageMap.new(source_paths: ["lib/widget.rb"], test_paths: tests,
                                        cache_dir: cache, project_root: dir).build_or_load
      end
      src = File.join(dir, "lib/widget.rb")
      assert_equal tests, map.tests_for(src, 1).sort
      hits = sentinel_processes(dir) do
        capture_io do
          Mutineer::CoverageMap.new(source_paths: ["lib/widget.rb"], test_paths: tests,
                                    cache_dir: cache, project_root: dir).build_or_load
        end
      end
      assert_equal [%w[a_check_test.rb], %w[a_check_test.rb b_check_test.rb], %w[b_check_test.rb]], hits
    end
  end

  # The RSpec capture script clears the load snapshot the same way.
  def test_rspec_standalone_capture_does_not_credit_an_unrelated_spec_with_load_lines
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib/price.rb"), STANDALONE_PRICE)
      FileUtils.mkdir_p(File.join(dir, "spec"))
      note = 'File.write(ENV["MUTINEER_SENTINEL"], "#{Process.pid} #{File.basename(__FILE__)}\n", mode: "a") if ENV["MUTINEER_SENTINEL"]'
      File.write(File.join(dir, "spec/price_spec.rb"), <<~RUBY)
        require_relative "../lib/price"
        #{note}
        RSpec.describe StandalonePrice do
          it("calls") { expect(StandalonePrice.called(2)).to eq(4) }
          it("endless") { expect(StandalonePrice.endless(2)).to eq(6) }
        end
      RUBY
      File.write(File.join(dir, "spec/caller_spec.rb"), <<~RUBY)
        require_relative "../lib/price"
        #{note}
        RSpec.describe "caller" do
          it("endless") { expect(StandalonePrice.endless(3)).to eq(9) }
        end
      RUBY
      File.write(File.join(dir, "spec/mail_spec.rb"), <<~RUBY)
        #{note}
        RSpec.describe "mail" do
          it("passes") { expect(1).to eq(1) }
        end
      RUBY
      cache = File.join(dir, "cache")
      map = nil
      capture_io { map = standalone_price_map(dir, cache, framework: "rspec") }
      assert_empty map.failed_test_files, "the specs ran"
      src = File.join(dir, "lib/price.rb")
      assert_equal %w[spec/price_spec.rb], map.tests_for(src, price_line("n * 2"))
      assert_equal %w[spec/price_spec.rb], map.tests_for(src, price_line("n + 9"))
      assert_equal %w[spec/caller_spec.rb spec/price_spec.rb], map.tests_for(src, price_line("n * 3")).sort
      assert map.ran_at_load?(src, price_line("n + 9"))
      hits = sentinel_processes(dir) { capture_io { standalone_price_map(dir, cache, framework: "rspec") } }
      assert_equal [%w[caller_spec.rb], %w[caller_spec.rb price_spec.rb], %w[price_spec.rb]], hits
    end
  end

  # A map saved before #426 still lists every test on the load lines. The
  # missing key rebuilds it, and the rebuilt map keeps the new rule.
  def test_standalone_cache_without_narrow_load_lines_rebuilds
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_standalone_price(dir)
      capture_io { standalone_price_map(dir, cache) }
      path = File.join(cache, "coverage.json")
      saved = JSON.parse(File.read(path))
      assert_equal true, saved["narrow_load_lines"]
      saved.delete("narrow_load_lines")
      saved["map"]["lib/price.rb:1"] = %w[test/price_test.rb test/mail_test.rb]
      File.write(path, JSON.generate(saved))

      rebuilt = nil
      capture_io { rebuilt = standalone_price_map(dir, cache) }
      assert rebuilt.phase_a_ran, "a cache from before load lines were narrowed must rebuild"
      assert_equal %w[test/price_test.rb], rebuilt.tests_for(File.join(dir, "lib/price.rb"), 1)
      third = nil
      capture_io { third = standalone_price_map(dir, cache) }
      refute third.phase_a_ran
    end
  end

  # infer_tests drops split tests when an exact spec exists, even if the run
  # did not select that spec. The content digest does not see it, so the saved
  # pairing has to. A hit would otherwise keep the split test as the only
  # owner of a load-only line.
  def test_an_unselected_exact_spec_rebuilds_the_load_line_map
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      FileUtils.mkdir_p(File.join(dir, "spec"))
      File.write(File.join(dir, "lib/price.rb"), "class SplitPrice\n  LOADED = 1\nend\n")
      %w[price_unit mail].each do |name|
        File.write(File.join(dir, "test/#{name}_test.rb"), <<~RUBY)
          require "minitest/autorun"
          class Split#{name.capitalize}Test < Minitest::Test
            def test_ok; assert_equal 1, 1; end
          end
        RUBY
      end
      cache = File.join(dir, "cache")
      tests = %w[test/price_unit_test.rb test/mail_test.rb]
      src = File.join(dir, "lib/price.rb")
      mk = lambda do
        Mutineer::CoverageMap.new(source_paths: ["lib/price.rb"], test_paths: tests,
                                  cache_dir: cache, project_root: dir).build_or_load
      end

      first = nil
      capture_io { first = mk.call }
      assert first.phase_a_ran
      assert_equal %w[test/price_unit_test.rb], first.tests_for(src, 1)
      second = nil
      capture_io { second = mk.call }
      refute second.phase_a_ran, "nothing on disk that pairing reads has changed"

      File.write(File.join(dir, "spec/price_spec.rb"), "RSpec.describe(SplitPrice)\n")
      rebuilt = nil
      capture_io { rebuilt = mk.call }
      assert rebuilt.phase_a_ran, "the spec replaces the split test, so the map must be captured again"
      assert_equal tests.sort, rebuilt.tests_for(src, 1).sort,
                   "no selected test pairs, so every test keeps the load-only line"
    end
  end

  # --- #421: a method-body edit recaptures part of the map ------------

  PARTIAL_TESTS = %w[test/caller_test.rb test/mail_test.rb test/price_test.rb test/shelf_test.rb].freeze
  SHELF_SOURCE = <<~RUBY
    class StandaloneShelf
      def self.bump(n)
        n + 1
      end

      MARK = 1
    end
  RUBY
  PARTIAL_SENTINEL = 'if ENV["MUTINEER_SENTINEL"]; _mode = defined?(Coverage) && Coverage.running? ? "capture" : "clean"; ' \
                     'File.write(ENV["MUTINEER_SENTINEL"], "#{Process.pid} #{File.basename(__FILE__)} #{_mode}\n", mode: "a"); end'

  def write_partial_app(dir, mail_extra: nil)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib/price.rb"), STANDALONE_PRICE)
    File.write(File.join(dir, "lib/shelf.rb"), SHELF_SOURCE)
    FileUtils.mkdir_p(File.join(dir, "test"))
    File.write(File.join(dir, "test/price_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/price"
      #{PARTIAL_SENTINEL}
      class StandalonePriceTest < Minitest::Test
        def test_called; assert_equal 4, StandalonePrice.called(2); end
        def test_endless; assert_equal 6, StandalonePrice.endless(2); end
        def test_both; assert_equal 8, StandalonePrice.both(2); end
        def test_loaded; assert_equal 10, StandalonePrice::LOADED; end
        def test_flunk; refute ENV["MUTINEER_FLUNK"]; end
      end
    RUBY
    File.write(File.join(dir, "test/caller_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/price"
      #{PARTIAL_SENTINEL}
      class StandaloneCallerTest < Minitest::Test
        def test_endless; assert_equal 9, StandalonePrice.endless(3); end
      end
    RUBY
    File.write(File.join(dir, "test/shelf_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/shelf"
      #{PARTIAL_SENTINEL}
      class StandaloneShelfTest < Minitest::Test
        def test_bump; assert_equal 2, StandaloneShelf.bump(1); end
        def test_mark; assert_equal 1, StandaloneShelf::MARK; end
      end
    RUBY
    File.write(File.join(dir, "test/mail_test.rb"), <<~RUBY)
      require "minitest/autorun"
      #{mail_extra}
      #{PARTIAL_SENTINEL}
      class StandaloneMailTest < Minitest::Test
        def test_ok; assert_equal 1, 1; end
      end
    RUBY
  end

  def partial_map(dir, cache, tests: PARTIAL_TESTS, **options)
    Mutineer::CoverageMap.new(source_paths: %w[lib/price.rb lib/shelf.rb], test_paths: tests,
                              cache_dir: cache, project_root: dir, **options).build_or_load
  end

  def with_sentinel(dir)
    sentinel = File.join(dir, "sentinel")
    File.write(sentinel, "")
    ENV["MUTINEER_SENTINEL"] = sentinel
    yield
    File.readlines(sentinel, chomp: true).map(&:split)
  ensure
    ENV.delete("MUTINEER_SENTINEL")
  end

  def captured_files(events)
    events.select { |row| row[2] == "capture" }.map { |row| row[1] }.sort
  end

  def assert_same_map(actual, expected)
    assert_equal expected.map, actual.map
    assert_equal expected.load_lines, actual.load_lines
    assert_equal expected.load_methods, actual.load_methods
  end

  # A same-line edit inside a method keeps the skeleton. The next run
  # recaptures the tests already in that source's map, not a test that only
  # loaded the file. The paired test still owns the load-only lines. An
  # unrelated test that was recaptured does not take them, or the other
  # source's load-only lines. The map matches a full capture.
  def test_method_body_edit_recaptures_only_the_tests_in_the_source_map
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      src = File.join(dir, "lib/price.rb")
      shelf = File.join(dir, "lib/shelf.rb")
      capture_io { partial_map(dir, cache) }
      saved = JSON.parse(File.read(File.join(cache, "coverage.json")))
      assert_equal saved["load_methods"].sort, saved["load_method_bodies"].keys.sort
      refute_includes saved["load_method_bodies"].values, "missing"

      File.write(src, File.read(src).sub("n * 2", "n * 2 + 0"))
      partial = nil
      err = nil
      events = with_sentinel(dir) { _, err = capture_io { partial = partial_map(dir, cache) } }
      assert_equal %w[caller_test.rb price_test.rb], captured_files(events)
      assert_includes err, "[mutineer] coverage cache: recaptured 2 of 4 test files; kept 2."
      assert partial.phase_a_ran
      full = nil
      capture_io { full = partial_map(dir, File.join(dir, "fresh")) }
      assert_same_map(partial, full)
      assert_equal %w[test/price_test.rb], partial.tests_for(src, price_line("class StandalonePrice"))
      assert_equal %w[test/price_test.rb], partial.tests_for(src, price_line("n + 9"))
      assert_equal %w[test/shelf_test.rb], partial.tests_for(shelf, 1)
      refute_includes events.map { |row| row[1] }, "mail_test.rb"

      third = nil
      again = with_sentinel(dir) { capture_io { third = partial_map(dir, cache) } }
      refute third.phase_a_ran, "the partial save is a hit on the next run"
      assert_empty captured_files(again)
    end
  end

  # Recapturing one new test must not credit it with a source's load-only
  # lines. The paired test keeps them.
  def test_recapturing_one_test_does_not_take_another_sources_load_lines
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      capture_io { partial_map(dir, cache) }
      File.write(File.join(dir, "test/extra_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/price"
        require_relative "../lib/shelf"
        #{PARTIAL_SENTINEL}
        class StandaloneExtraTest < Minitest::Test
          def test_ok; assert_equal 1, 1; end
        end
      RUBY
      tests = PARTIAL_TESTS + ["test/extra_test.rb"]
      partial = nil
      events = with_sentinel(dir) { capture_io { partial = partial_map(dir, cache, tests: tests) } }
      assert_equal %w[extra_test.rb], captured_files(events)
      full = nil
      capture_io { full = partial_map(dir, File.join(dir, "fresh"), tests: tests) }
      assert_same_map(partial, full)
      src = File.join(dir, "lib/price.rb")
      assert_equal %w[test/price_test.rb], partial.tests_for(src, price_line("n + 9"))
      assert_equal %w[test/shelf_test.rb], partial.tests_for(File.join(dir, "lib/shelf.rb"), 1)
    end
  end

  # A class-body edit can change which lines run at load. Every test is
  # captured again.
  def test_class_body_edit_recaptures_every_test
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      capture_io { partial_map(dir, cache) }
      src = File.join(dir, "lib/price.rb")
      File.write(src, File.read(src).sub("class StandalonePrice", "class StandalonePrice # edited"))
      events = with_sentinel(dir) { capture_io { partial_map(dir, cache) } }
      assert_equal %w[caller_test.rb mail_test.rb price_test.rb shelf_test.rb], captured_files(events)
    end
  end

  # A method that ran at load can change a value another test reads. Its body
  # is not a partial recapture, even when the line numbers stay put.
  def test_load_method_body_edit_recaptures_every_test
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      capture_io { partial_map(dir, cache) }
      src = File.join(dir, "lib/price.rb")
      File.write(src, File.read(src).sub("n + 9", "n + 8 + 1"))
      events = with_sentinel(dir) { capture_io { partial_map(dir, cache) } }
      assert_equal %w[caller_test.rb mail_test.rb price_test.rb shelf_test.rb], captured_files(events)
    end
  end

  # An added line moves every later line. The old map keys would be wrong,
  # so the run captures every test.
  def test_added_line_inside_a_method_recaptures_every_test
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      capture_io { partial_map(dir, cache) }
      src = File.join(dir, "lib/price.rb")
      File.write(src, File.read(src).sub("n * 2", "_ = 0\n        n * 2"))
      events = with_sentinel(dir) { capture_io { partial_map(dir, cache) } }
      assert_equal %w[caller_test.rb mail_test.rb price_test.rb shelf_test.rb], captured_files(events)
    end
  end

  # Editing one test file recaptures that file. The paired test keeps the
  # load-only lines, and the map matches a full capture.
  def test_test_file_edit_recaptures_only_that_test
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      capture_io { partial_map(dir, cache) }
      mail = File.join(dir, "test/mail_test.rb")
      File.write(mail, File.read(mail) + "# note\n")
      partial = nil
      events = with_sentinel(dir) { capture_io { partial = partial_map(dir, cache) } }
      assert_equal %w[mail_test.rb], captured_files(events)
      full = nil
      capture_io { full = partial_map(dir, File.join(dir, "fresh")) }
      assert_same_map(partial, full)
      assert_equal %w[test/price_test.rb], partial.tests_for(File.join(dir, "lib/price.rb"), price_line("n + 9"))
      saved = JSON.parse(File.read(File.join(cache, "coverage.json")))
      fresh = JSON.parse(File.read(File.join(dir, "fresh", "coverage.json")))
      assert_equal fresh["dependencies"].keys.sort, saved["dependencies"].keys.sort,
                   "a recaptured test file is not a loaded dependency"

      File.write(mail, File.read(mail) + "# second note\n")
      again = with_sentinel(dir) { capture_io { partial_map(dir, cache) } }
      assert_equal %w[mail_test.rb], captured_files(again), "a second edit of the same test is still partial"
    end
  end

  # A project file outside the run's sources still recaptures every test.
  # Per-test executed files are the rest of #421.
  def test_loaded_helper_edit_recaptures_every_test
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      helper = File.join(dir, "test/mail_helper.rb")
      write_partial_app(dir, mail_extra: 'require_relative "mail_helper"')
      File.write(helper, "MAIL_HELPER = 1\n")
      capture_io { partial_map(dir, cache) }
      File.write(helper, "MAIL_HELPER = 2\n")
      events = with_sentinel(dir) { capture_io { partial_map(dir, cache) } }
      assert_equal %w[caller_test.rb mail_test.rb price_test.rb shelf_test.rb], captured_files(events)
    end
  end

  # A kept test can load a file the run no longer selects. Dropping that
  # test must keep the file's fingerprint, or a later edit to it reuses
  # stale coverage on a cache hit.
  def test_a_removed_test_file_that_a_kept_test_loads_stays_a_dependency
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir, mail_extra: 'require_relative "caller_test"')
      kept = PARTIAL_TESTS - %w[test/caller_test.rb]
      capture_io { partial_map(dir, cache) }
      capture_io { partial_map(dir, cache, tests: kept) }
      saved = JSON.parse(File.read(File.join(cache, "coverage.json")))
      assert_includes saved["dependencies"].keys, "test/caller_test.rb"

      caller = File.join(dir, "test/caller_test.rb")
      File.write(caller, "#{File.read(caller)}CALLER_EDIT = 1\n")
      events = with_sentinel(dir) { capture_io { partial_map(dir, cache, tests: kept) } }
      refute_empty captured_files(events), "an edit to a file a kept test loads must not be a cache hit"
    end
  end

  # A `--require` file is a run input. Changing it captures every test.
  def test_require_file_edit_recaptures_every_test
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      setup = File.join(dir, "setup.rb")
      File.write(setup, "PARTIAL_SETUP = 1\n")
      build = -> { partial_map(dir, cache, require_paths: ["setup"]) }
      capture_io { build.call }
      File.write(setup, "PARTIAL_SETUP = 2\n")
      events = with_sentinel(dir) { capture_io { build.call } }
      assert_equal %w[caller_test.rb mail_test.rb price_test.rb shelf_test.rb], captured_files(events)
    end
  end

  # Dropping the paired test changes who may keep a load-only line. The run
  # captures every remaining test, and the map matches a full capture.
  def test_removing_the_paired_test_recaptures_every_remaining_test
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      capture_io { partial_map(dir, cache) }
      tests = PARTIAL_TESTS - ["test/price_test.rb"]
      partial = nil
      events = with_sentinel(dir) { capture_io { partial = partial_map(dir, cache, tests: tests) } }
      assert_equal %w[caller_test.rb mail_test.rb shelf_test.rb], captured_files(events)
      full = nil
      capture_io { full = partial_map(dir, File.join(dir, "fresh"), tests: tests) }
      assert_same_map(partial, full)
    end
  end

  # A red covering test is recorded on the partial recapture, which is what
  # stops the run before any mutant.
  def test_partial_recapture_records_a_red_covering_test
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      capture_io { partial_map(dir, cache) }
      src = File.join(dir, "lib/price.rb")
      File.write(src, File.read(src).sub("n * 2", "n * 2 + 0"))
      before = JSON.parse(File.read(File.join(cache, "coverage.json")))["digest"]
      partial = nil
      full = nil
      with_env("MUTINEER_FLUNK" => "1") do
        capture_io { partial = partial_map(dir, cache) }
        capture_io { full = partial_map(dir, File.join(dir, "fresh")) }
      end
      assert_includes partial.failed_clean_tests, "test/price_test.rb"
      assert_same_map(partial, full)
      saved = JSON.parse(File.read(File.join(cache, "coverage.json")))
      assert_equal before, saved["digest"], "a red suite does not replace the cache"
    end
  end

  # A capture that failed last time (`failed_test_files`) is captured again
  # on a partial run, even when it is not in the edited source's map, and
  # the failure is cleared once it captures.
  def test_partial_recapture_retries_a_previously_failed_capture
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      capture_io { partial_map(dir, cache) }
      path = File.join(cache, "coverage.json")
      saved = JSON.parse(File.read(path))
      saved["failed_test_files"] = %w[test/mail_test.rb]
      File.write(path, JSON.generate(saved))

      src = File.join(dir, "lib/price.rb")
      File.write(src, File.read(src).sub("n * 2", "n * 2 + 0"))
      partial = nil
      events = with_sentinel(dir) { capture_io { partial = partial_map(dir, cache) } }
      assert_equal %w[caller_test.rb mail_test.rb price_test.rb], captured_files(events)
      assert_empty partial.failed_test_files
      assert_empty JSON.parse(File.read(path))["failed_test_files"]
    end
  end

  # A cache from before the partial-recapture keys is rebuilt once.
  def test_cache_without_run_inputs_recaptures_every_test
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      write_partial_app(dir)
      capture_io { partial_map(dir, cache) }
      path = File.join(cache, "coverage.json")
      saved = JSON.parse(File.read(path))
      saved.delete("run_inputs")
      File.write(path, JSON.generate(saved))
      events = with_sentinel(dir) { capture_io { partial_map(dir, cache) } }
      assert_equal %w[caller_test.rb mail_test.rb price_test.rb shelf_test.rb], captured_files(events)
    end
  end

  # The skeleton ignores a same-line body edit and changes when a line is
  # added or the class body changes.
  def test_source_skeleton_ignores_a_same_line_method_body
    Dir.mktmpdir do |dir|
      path = File.join(dir, "price.rb")
      File.write(path, STANDALONE_PRICE)
      map = Mutineer::CoverageMap.new(source_paths: [path], test_paths: [], cache_dir: dir, project_root: dir)
      original = map.send(:source_skeleton_digest, path)
      File.write(path, STANDALONE_PRICE.sub("n * 2", "n * 2 + 0"))
      assert_equal original, map.send(:source_skeleton_digest, path)
      File.write(path, STANDALONE_PRICE.sub("n * 2", "_ = 0\n        n * 2"))
      refute_equal original, map.send(:source_skeleton_digest, path)
      File.write(path, STANDALONE_PRICE.sub("class StandalonePrice", "class StandalonePrice # edited"))
      refute_equal original, map.send(:source_skeleton_digest, path)
    end
  end

  # The skeleton rule across real files, not one example: for defs in every
  # `lib/` and fixture file, a same-line edit inside the body keeps the
  # skeleton, a new line inside the body changes it, and so do an edit just
  # before a `def` that is not inside another body and a same-line rename.
  def test_source_skeleton_rule_holds_across_real_ruby_files
    root = File.expand_path("..", __dir__)
    files = Dir[File.join(root, "{lib,test/fixtures}/**/*.rb")].sort
    checked = 0
    skipped = 0
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sample.rb")
      map = Mutineer::CoverageMap.new(source_paths: [path], test_paths: [], cache_dir: dir, project_root: dir)
      digest = lambda do |text|
        File.binwrite(path, text)
        map.send(:source_skeleton_digest, path)
      end
      files.each do |file|
        source = File.binread(file)
        result = Prism.parse(source)
        next unless result.errors.empty?

        defs = []
        map.send(:each_def, result.value) { |node| defs << node }
        sample = defs.reject { |node| node.equal_loc || node.body.nil? }
        sample = sample.values_at(0, sample.size / 2, -1).compact.uniq
        original = digest.call(source)
        next skipped += 1 if original.nil?

        sample.each do |node|
          body = node.body
          first = body.is_a?(Prism::BeginNode) ? body.statements&.location : body.location
          next skipped += 1 if first.nil?

          at = first.start_offset
          same_line = source.byteslice(0, at) + "nil; " + source.byteslice(at..)
          new_line = source.byteslice(0, at) + "nil\n" + source.byteslice(at..)
          start = node.location.start_offset
          nested = defs.any? do |other|
            loc = other.body&.location
            !other.equal?(node) && loc && loc.start_offset <= start && start < loc.end_offset
          end
          before_def = source.byteslice(0, start) + "nil; " + source.byteslice(start..)
          name_end = node.name_loc.end_offset
          renamed = source.byteslice(0, name_end) + "_x" + source.byteslice(name_end..)
          edited = [same_line, new_line, before_def, renamed].map { |text| [text, Prism.parse(text).errors.empty?] }
          next skipped += 1 unless edited.all?(&:last)

          label = "#{file.delete_prefix("#{root}/")}:#{node.location.start_line}"
          # A nested def on the edited line moves; its position is part of the skeleton.
          shifts_def = defs.any? { |other| other.location.start_line == first.start_line && other.location.start_offset >= at }
          assert_equal original, digest.call(same_line), "same-line body edit at #{label}" unless shifts_def
          refute_equal original, digest.call(new_line), "added body line at #{label}"
          refute_equal original, digest.call(before_def), "edit before def at #{label}" unless nested
          refute_equal original, digest.call(renamed), "same-line rename at #{label}" unless nested
          checked += 1
        end
      end
    end
    assert_operator checked, :>=, 200, "too few defs checked (#{checked}, skipped #{skipped})"
    assert_operator skipped, :<=, checked / 10, "too many inputs skipped (#{skipped} of #{checked + skipped})"
  end

  # Boot mode clears coverage before each test. A method-body edit recaptures
  # the test in the source's map, not the test that only saw the file at boot.
  def test_boot_method_body_edit_recaptures_only_the_covering_test
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "alpha.rb"), <<~RUBY)
        class BootPartialAlpha
          def self.double(x)
            x * 2
          end

          def self.widen(x)
            x + 1
          end
        end
      RUBY
      File.write(File.join(dir, "beta.rb"), <<~RUBY)
        require_relative "alpha"
        class BootPartialBeta
          WIDTH = BootPartialAlpha.widen(3)

          def self.half(x)
            x / 2
          end
        end
      RUBY
      File.write(File.join(dir, "boot.rb"), "require_relative \"alpha\"\nrequire_relative \"beta\"\n")
      note = PARTIAL_SENTINEL
      File.write(File.join(dir, "alpha_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "alpha"
        #{note}
        class BootPartialAlphaTest < Minitest::Test
          def test_double; assert_equal 6, BootPartialAlpha.double(3); end
        end
      RUBY
      File.write(File.join(dir, "beta_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "beta"
        #{note}
        class BootPartialBetaTest < Minitest::Test
          def test_half; assert_equal 2, BootPartialBeta.half(4); end
          def test_width; assert_equal 4, BootPartialBeta::WIDTH; end
        end
      RUBY
      cache = File.join(dir, "cache")
      first = boot_partial_run(dir, cache)
      assert first["phase_a_ran"], first["stderr"]
      assert_empty first["failed"], first["stderr"]

      alpha = File.read(File.join(dir, "alpha.rb"))
      File.write(File.join(dir, "alpha.rb"), alpha.sub("x * 2", "x * 2 + 0"))
      partial = boot_partial_run(dir, cache)
      assert_equal %w[alpha_test.rb], partial["captures"], partial["stderr"]
      assert_includes partial["stderr"], "recaptured 1 of 2 test files; kept 1."
      full = boot_partial_run(dir, File.join(dir, "fresh"))
      assert_equal full["map"], partial["map"]
      assert_equal full["load_lines"], partial["load_lines"]
      assert_equal full["load_methods"], partial["load_methods"]
    end
  end

  def boot_partial_run(dir, cache)
    require "open3"
    script = <<~RUBY
      require "coverage"
      require "json"
      require "mutineer"
      dir, cache = ARGV
      Coverage.start(lines: true, methods: true)
      require File.join(dir, "boot.rb")
      ENV["MUTINEER_SENTINEL"] = File.join(dir, "sentinel")
      map = Mutineer::CoverageMap.new(source_paths: ["alpha.rb"], test_paths: ["alpha_test.rb", "beta_test.rb"],
                                      cache_dir: cache, project_root: dir, boot_path: "boot.rb").build_via_fork
      puts JSON.generate("phase_a_ran" => map.phase_a_ran, "map" => map.map,
                         "load_lines" => map.load_lines.to_a.sort,
                         "load_methods" => map.load_methods.to_a.sort,
                         "failed" => map.failed_test_files, "clean" => map.failed_clean_tests)
    RUBY
    File.write(File.join(dir, "sentinel"), "")
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{File.join(ROOT, "lib")}", "-e", script, dir, cache)
    flunk("#{status.exitstatus}: #{stderr}") unless status.success?

    result = JSON.parse(stdout.lines.grep(/\A\{/).last)
    result["stderr"] = stderr
    result["captures"] = File.readlines(File.join(dir, "sentinel"), chomp: true)
                              .map(&:split).select { |row| row[2] == "capture" }.map { |row| row[1] }.sort
    result
  end

  # --- #187: lines that ran at load ---------------------------------------

  LOAD_ROOT = File.expand_path("fixtures/load_time", __dir__)
  CATALOG = File.join(LOAD_ROOT, "lib/catalog.rb")

  def build_catalog(cache_dir)
    Mutineer::CoverageMap.new(source_paths: ["lib/catalog.rb"], test_paths: ["test/catalog_test.rb"],
                              cache_dir: cache_dir, project_root: LOAD_ROOT).build_or_load
  end

  # Standalone capture reads the lines the source ran when it was required,
  # before the test file loads: `base * 2` (line 7) ran to build ALL.
  def test_standalone_capture_records_load_lines_and_the_cache_keeps_them
    dir = Dir.mktmpdir("mutineer-cache")
    first = build_catalog(dir)
    assert first.phase_a_ran
    assert first.ran_at_load?(CATALOG, 7), "base * 2 ran at load"
    assert_equal ["test/catalog_test.rb"], first.tests_for(CATALOG, 7),
                 "the paired test keeps a line that ran only at load"
    refute first.ran_at_load?(File.join(LOAD_ROOT, "test/catalog_test.rb"), 8), "only source lines are kept"

    second = build_catalog(dir)
    refute second.phase_a_ran, "digest matched: cache hit"
    assert_equal first.load_lines, second.load_lines
  end

  def test_cache_without_load_lines_is_rebuilt_once
    dir = Dir.mktmpdir("mutineer-cache")
    build_catalog(dir)
    path = File.join(dir, "coverage.json")
    File.write(path, JSON.generate(JSON.parse(File.read(path)).except("load_lines", "load_methods")))

    rebuilt = build_catalog(dir)
    assert rebuilt.phase_a_ran, "a cache from before load lines were saved must rebuild"
    assert rebuilt.ran_at_load?(CATALOG, 7)
  end

  # #209: the capture records which methods were called at load, by the
  # line and column of their def, and a cache from before #209 rebuilds once.
  def test_standalone_capture_records_load_methods_and_an_old_cache_rebuilds
    dir = Dir.mktmpdir("mutineer-cache")
    first = build_catalog(dir)
    assert first.method_ran_at_load?(CATALOG, 6, 2), "Catalog.price ran at load"
    refute first.method_ran_at_load?(CATALOG, 6, 0)

    path = File.join(dir, "coverage.json")
    File.write(path, JSON.generate(JSON.parse(File.read(path)).except("load_methods")))
    rebuilt = build_catalog(dir)
    assert rebuilt.phase_a_ran, "a cache from before load methods were saved must rebuild"
    assert rebuilt.method_ran_at_load?(CATALOG, 6, 2)
    refute build_catalog(dir).phase_a_ran, "the rebuilt cache keeps them"
    assert build_catalog(dir).method_ran_at_load?(CATALOG, 6, 2)
  end

  # #217: the capture loads the `--require` files after the sources and before
  # it reads the load coverage, and the files are part of the cache digest.
  def test_require_paths_run_at_load_and_invalidate_the_cache
    dir = Dir.mktmpdir("mutineer-proj")
    cache = Dir.mktmpdir("mutineer-cache")
    src = File.join(dir, "req_price.rb")
    setup = File.join(dir, "req_setup.rb")
    test = File.join(dir, "req_price_test.rb")
    File.write(src, "class ReqPrice\n  def self.price(x)\n    x * 2\n  end\nend\n")
    File.write(setup, "REQ_TABLE = [ReqPrice.price(3)].freeze\n")
    FileUtils.mkdir_p(File.join(dir, "req_setup")) # a gem-style folder beside req_setup.rb
    File.write(test, "require \"minitest/autorun\"\nclass ReqPriceTest < Minitest::Test\n  " \
                     "def test_table; assert_equal [6], REQ_TABLE; end\nend\n")
    mk = lambda do |requires|
      Mutineer::CoverageMap.new(source_paths: [src], test_paths: [test], cache_dir: cache,
                                project_root: dir, require_paths: requires).build_or_load
    end

    first = mk.call(["req_setup"])
    assert first.phase_a_ran
    assert_empty first.failed_test_files, "the test sees the constant the require file built"
    assert first.ran_at_load?(src, 3), "x * 2 ran while the require file loaded"
    refute mk.call(["req_setup"]).phase_a_ran, "unchanged: cache hit"

    File.write(setup, "REQ_TABLE = [ReqPrice.price(1 + 2)].freeze\n")
    assert mk.call(["req_setup"]).phase_a_ran, "require file changed: cache must rebuild"
    dropped = nil
    capture_subprocess_io { dropped = mk.call([]) } # the test now fails: REQ_TABLE is undefined
    assert dropped.phase_a_ran, "require file dropped: cache must rebuild"
  end

  # The `--require` files load in the order given, and the order can change
  # what they build, so it is part of the digest.
  def test_digest_is_require_order_sensitive
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "A = 1\n")
      File.write(File.join(dir, "b.rb"), "B = 2\n")
      mk = lambda do |reqs|
        Mutineer::CoverageMap.new(source_paths: [], test_paths: [], cache_dir: dir, project_root: dir,
                                  require_paths: reqs)
      end
      refute_equal mk.call(%w[a b]).send(:compute_digest), mk.call(%w[b a]).send(:compute_digest)
    end
  end

  # The seed sets the test order, so a map captured under another seed is not
  # reused (#282). Minitest reads SEED. RSpec reads the pinned seed and SPEC_OPTS.
  # The partial-recapture digest (#421) must see the same changes, or a seed
  # change would keep the old map with nothing recaptured.
  def test_digest_is_minitest_seed_sensitive
    %i[compute_digest run_inputs_digest].each { |name| assert_seed_sensitive(name) }
  end

  def assert_seed_sensitive(name)
    Dir.mktmpdir do |dir|
      make = ->(framework) {
        Mutineer::CoverageMap.new(source_paths: [], test_paths: [], cache_dir: dir, project_root: dir,
                                  framework: framework)
      }
      digest = lambda do |seed, framework, spec_opts: nil|
        prior = ENV.fetch("SEED", nil)
        prior_opts = ENV.fetch("SPEC_OPTS", nil)
        seed ? ENV["SEED"] = seed : ENV.delete("SEED")
        spec_opts ? ENV["SPEC_OPTS"] = spec_opts : ENV.delete("SPEC_OPTS")
        make.call(framework).send(name)
      ensure
        prior ? ENV["SEED"] = prior : ENV.delete("SEED")
        prior_opts ? ENV["SPEC_OPTS"] = prior_opts : ENV.delete("SPEC_OPTS")
      end
      refute_equal digest.call(nil, "minitest"), digest.call("2", "minitest"), name
      assert_equal digest.call(nil, "minitest"), digest.call("1", "minitest"), name
      assert_equal digest.call(nil, "rspec"), digest.call("2", "rspec"), name
      refute_equal digest.call(nil, "rspec"), digest.call(nil, "rspec", spec_opts: "--seed 2"), name
      bare = digest.call(nil, "rspec")
      File.write(File.join(dir, ".rspec"), "--seed 7\n")
      with_file = make.call("rspec").send(name)
      refute_equal bare, with_file, name
      File.write(File.join(dir, ".rspec"), "--seed 8\n")
      refute_equal with_file, make.call("rspec").send(name), name
    end
  end

  # `require` also finds a native extension without its suffix.
  def test_digest_reads_an_extensionless_native_require
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "native.#{RbConfig::CONFIG['DLEXT']}"), "binary")
      map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], cache_dir: dir, project_root: dir,
                                      require_paths: ["native"])
      assert_kind_of String, map.send(:compute_digest)
    end
  end

  # Boot mode reads the lines that ran during boot from the parent's Coverage,
  # on every run: no forked capture is credited with them.
  def test_build_via_fork_records_the_lines_that_ran_at_boot
    ensure_coverage_running
    dir = Dir.mktmpdir("mutineer-proj")
    src = File.join(dir, "boot_load.rb")
    test = File.join(dir, "boot_load_test.rb")
    File.write(src, "class BootLoadThing\n  def self.price(x)\n    x * 2\n  end\n\n  ALL = [price(3)].freeze\n" \
                    "  def self.half(x) = x / 2\nend\n")
    File.write(test, "require \"minitest/autorun\"\nclass BootLoadThingTest < Minitest::Test\n  " \
                     "def test_all; assert_equal [6], BootLoadThing::ALL; end\n  " \
                     "def test_half; assert_equal 2, BootLoadThing.half(4); end\nend\n")
    require File.realpath(src) # the fork capture matches the source by its real path

    cache = Dir.mktmpdir("mutineer-cache")
    mk = lambda do
      Mutineer::CoverageMap.new(source_paths: [src], test_paths: [test], cache_dir: cache,
                                project_root: dir, boot_path: src).build_via_fork
    end
    map = mk.call
    assert map.ran_at_load?(src, 3), "x * 2 ran while the class loaded"
    assert_empty map.tests_for(src, 3), "no test ran it"
    # #209: price was called at boot, half only by the test, which gets the
    # credit for the def line of the endless half.
    assert map.method_ran_at_load?(src, 2, 2)
    refute map.method_ran_at_load?(src, 7, 2)
    assert_equal [File.basename(test)], map.tests_for(src, 7)
    assert mk.call.ran_at_load?(src, 3), "a cache hit still reads the boot lines"
  end

  # #209: a test is credited with the def line of a method it called, but not
  # when another method starts on that line, since the map keys tests by line.
  def test_lines_with_called_defs_skips_a_line_shared_by_two_methods
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [])
    data = { lines: [0, 0, nil], methods: { [Object, :a, 1, 0, 1, 18] => 0, [Object, :b, 1, 20, 1, 38] => 1,
                                           [Object, :c, 2, 0, 2, 18] => 2 } }
    assert_equal [0, 2, nil], map.send(:lines_with_called_defs, data)
    rows = { "lines" => [0, 0, nil], "methods" => [[1, 0, 0], [1, 20, 1], [2, 0, 2]] }
    assert_equal [0, 2, nil], map.send(:lines_with_called_defs, rows), "the capture JSON uses the same rule"
  end

  def test_from_data_takes_load_lines
    map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: [], project_root: LOAD_ROOT,
                                          load_lines: ["lib/catalog.rb:7"], load_methods: ["lib/catalog.rb:6:2"])
    assert map.ran_at_load?(CATALOG, 7)
    assert map.method_ran_at_load?(CATALOG, 6, 2)
    refute map.ran_at_load?(CATALOG, 6)
    refute Mutineer::CoverageMap.from_data(map: {}, failed_test_files: [], project_root: LOAD_ROOT)
                                .ran_at_load?(CATALOG, 7)
  end

  # #203: the paired file first, then the cheapest; a file with no timing last.
  # Costs in one doubling bucket (2.0 s and 2.4 s) tie, and the path breaks it.
  def test_order_tests_puts_paired_files_first_then_the_cheapest
    dir = Dir.mktmpdir("mutineer-order")
    FileUtils.mkdir_p(File.join(dir, "lib/shop"))
    FileUtils.mkdir_p(File.join(dir, "test/shop"))
    File.write(File.join(dir, "lib/shop/cart.rb"), "")
    File.write(File.join(dir, "test/shop/cart_test.rb"), "")
    timings = { "test/shop/cart_test.rb" => 9.0, "test/a0_slow_test.rb" => 8.0,
                "test/fast_test.rb" => 0.5, "test/b_tie_test.rb" => 2.0, "test/a_tie_test.rb" => 2.4 }
    map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: [], project_root: dir, timings: timings)
    tests = %w[test/untimed_test.rb test/a0_slow_test.rb test/b_tie_test.rb test/shop/cart_test.rb
               test/a_tie_test.rb test/fast_test.rb]

    expected = %w[test/shop/cart_test.rb test/fast_test.rb test/a_tie_test.rb test/b_tie_test.rb
                  test/a0_slow_test.rb test/untimed_test.rb]
    assert_equal expected, map.order_tests(File.join(dir, "lib/shop/cart.rb"), tests)
    assert_equal expected, map.order_tests("lib/shop/cart.rb", tests.reverse)

    # A startup cost that every capture pays does not blur the buckets.
    slow_start = timings.transform_values { |t| t + 30 }
    map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: [], project_root: dir, timings: slow_start)
    assert_equal expected, map.order_tests("lib/shop/cart.rb", tests)

    # A failed capture, timed again on each run, does not set that startup cost.
    map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: ["test/crash_test.rb"], project_root: dir,
                                          timings: slow_start.merge("test/crash_test.rb" => 0.01))
    assert_equal expected, map.order_tests("lib/shop/cart.rb", tests)
  end

  # A concern's namespace split runs before a cheaper unrelated file.
  def test_order_tests_puts_a_concern_namespace_split_first
    dir = Dir.mktmpdir("mutineer-order")
    source = "app/models/concerns/storage/totaled.rb"
    paired = "test/models/storage/totaled_bytes_test.rb"
    extra = "test/other_test.rb"
    [source, paired, extra].each do |rel|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "")
    end
    timings = { paired => 9.0, extra => 0.1 }
    map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: [], project_root: dir, timings: timings)

    assert_equal [paired, extra], map.order_tests(File.join(dir, source), [extra, paired])
  end

  # A concern's namespace test runs before a cheaper unrelated file.
  def test_order_tests_puts_a_concern_namespace_test_first
    dir = Dir.mktmpdir("mutineer-order")
    source = "app/models/concerns/storage/totaled.rb"
    paired = "test/models/storage/totaled_test.rb"
    extra = "test/other_test.rb"
    [source, paired, extra].each do |rel|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "")
    end
    timings = { paired => 9.0, extra => 0.1 }
    map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: [], project_root: dir, timings: timings)

    assert_equal [paired, extra], map.order_tests(File.join(dir, source), [extra, paired])
  end

  def test_capture_records_a_timing_per_test_file_and_the_cache_keeps_them
    dir = Dir.mktmpdir("mutineer-cache")
    first = build_catalog(dir)
    assert_equal ["test/catalog_test.rb"], first.timings.keys
    assert_kind_of Float, first.timings["test/catalog_test.rb"]

    second = build_catalog(dir)
    refute second.phase_a_ran, "digest matched: cache hit"
    assert_equal first.timings, second.timings
  end

  def test_cache_without_timings_is_rebuilt_once
    dir = Dir.mktmpdir("mutineer-cache")
    build_catalog(dir)
    path = File.join(dir, "coverage.json")
    File.write(path, JSON.generate(JSON.parse(File.read(path)).except("timings")))

    rebuilt = build_catalog(dir)
    assert rebuilt.phase_a_ran, "a cache from before timings were saved must rebuild"
    assert_equal ["test/catalog_test.rb"], rebuilt.timings.keys
    refute build_catalog(dir).phase_a_ran, "the rebuilt cache is a hit"
  end

  # Rails reads PARALLEL_WORKERS inside parallelize. A map saved before that
  # value was recorded, or saved for another value, must not select tests.
  def test_old_parallel_worker_cache_is_rebuilt
    dir = Dir.mktmpdir("mutineer-cache")
    path = File.join(dir, "coverage.json")
    prior = ENV.fetch("PARALLEL_WORKERS", nil)
    ENV["PARALLEL_WORKERS"] = "1"
    begin
      build_catalog(dir)
      payload = JSON.parse(File.read(path))
      assert_equal "1", payload["parallel_workers"]

      File.write(path, JSON.generate(payload.except("parallel_workers")))
      rebuilt = build_catalog(dir)
      assert rebuilt.phase_a_ran, "a cache from before parallel workers were recorded must rebuild"

      saved = JSON.parse(File.read(path))
      assert_equal "1", saved["parallel_workers"]
      saved["parallel_workers"] = "4"
      File.write(path, JSON.generate(saved))
      again = build_catalog(dir)
      assert again.phase_a_ran, "a map captured with other Rails workers must rebuild"

      refute build_catalog(dir).phase_a_ran, "the same worker value is a cache hit"
    ensure
      prior.nil? ? ENV.delete("PARALLEL_WORKERS") : ENV["PARALLEL_WORKERS"] = prior
    end
  end

  def test_corrupt_cache_is_rebuilt
    dir = Dir.mktmpdir("mutineer-cache")
    File.write(File.join(dir, "coverage.json"), "{not valid json")
    map = build([STRONG_TEST], cache_dir: dir)
    assert map.phase_a_ran
    refute_empty map.tests_for(CALC, line_of("a + b"))
  end

  # --- Acceptance: runner Phase B selection --------------------------------

  def plus_mutation
    source = File.read(CALC)
    plus = source.index("a + b") + 2
    Mutineer::Mutation.new(start_offset: plus, end_offset: plus + 1,
                         replacement: "-", operator: :arithmetic)
  end

  def modulo_mutation
    source = File.read(CALC)
    mod = source.index("a % b") + 2
    Mutineer::Mutation.new(start_offset: mod, end_offset: mod + 1,
                         replacement: "*", operator: :arithmetic)
  end

  def test_mutation_on_uncovered_line_is_no_coverage
    map = build([ADD_ONLY_TEST]) # no test exercises #modulo
    result = Mutineer::Runner.run(modulo_mutation, source_file: CALC, coverage_map: map)
    assert_predicate result, :no_coverage?, "got #{result.status}"
  end

  def test_mutation_on_covered_line_runs_and_is_killed
    map = build([STRONG_TEST])
    result = Mutineer::Runner.run(plus_mutation, source_file: CALC, coverage_map: map)
    assert_predicate result, :killed?, "got #{result.status} (#{result.details})"
  end

  # --- R6: non-JSON / R3 timeout / Hash-format coverage --------------------

  # Stdout is not the result channel, so plain output never corrupts a capture.
  # Only bytes written to the result fd itself can.
  def test_non_json_result_output_is_skipped_not_fatal
    bad = File.join(Dir.mktmpdir, "noisy_test.rb")
    File.write(bad, %(IO.for_fd(#{Mutineer::CoverageMap::RESULT_FD}, autoclose: false).syswrite("GARBAGE NOT JSON")\n))
    map = nil
    _, err = capture_subprocess_io { map = build([STRONG_TEST, bad]) }
    assert_includes map.failed_test_files.map { |f| File.basename(f) }, "noisy_test.rb"
    assert_includes err, "invalid coverage output"
    refute_empty map.tests_for(CALC, line_of("a + b")), "good test still recorded"
  end

  def test_capture_subprocess_stdout_is_silenced_and_stderr_passes_through
    noisy = File.join(Dir.mktmpdir, "noisy_test.rb")
    File.write(noisy, %(puts "NOISE-ON-STDOUT"\nsystem("echo NOISE-FROM-SUBPROCESS")\nwarn "NOISE-ON-STDERR"\n))
    map = nil
    out, err = capture_subprocess_io { map = build([STRONG_TEST, noisy]) }
    assert_empty map.failed_test_files
    assert_empty out
    assert_includes err, "NOISE-ON-STDERR"
  end

  # Boot mode forks the parent instead of spawning a subprocess; the fork
  # boundary silences stdout there.
  def test_fork_capture_and_fork_clean_check_silence_stdout
    ensure_coverage_running
    noisy = File.expand_path("fixtures/noisy_minitest_test.rb", __dir__)
    map = fork_map(noisy, verbose: true)
    payload = clean = nil
    out, = capture_subprocess_io do
      payload = map.send(:fork_capture, noisy, [CALC], nil)
      clean, = map.send(:fork_clean_pass?, [noisy], nil)
    end
    assert_kind_of Hash, payload
    assert payload["passed"]
    assert clean
    assert_empty out
  end

  # The timeout bounds the good capture too: a fresh Ruby that loads Bundler and
  # Minitest. That takes about 0.2s, but up to 2.5s on a very busy machine, so 5s.
  # The hang file runs first, so the good capture shows the build goes on after it.
  def test_hanging_test_file_times_out_and_is_skipped
    hang = File.join(Dir.mktmpdir, "hang_test.rb")
    File.write(hang, "sleep 30\n")
    map = nil
    _, err = capture_subprocess_io do
      map = Mutineer::CoverageMap.new(
        source_paths: [CALC], test_paths: [hang, STRONG_TEST],
        cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, capture_timeout: 5
      ).build_or_load
    end
    assert_equal ["hang_test.rb"], map.failed_test_files.map { |f| File.basename(f) }
    assert_includes err, "timed out after 5s"
    refute_empty map.tests_for(CALC, line_of("a + b")), "good test still recorded"
  end

  def test_record_handles_hash_format_coverage_lines
    map = build([STRONG_TEST])
    src = File.join(ROOT, "lib", "made_up.rb") # in-project absolute path
    map.send(:record, { src => { "lines" => [nil, 1, 0, 2] } }, "t_test.rb")
    assert_equal ["t_test.rb"], map.tests_for(src, 2)
    assert_empty map.tests_for(src, 3) # count 0 => uncovered
  end

  # --- R4: digest path / role sensitivity ----------------------------------

  def test_digest_is_path_sensitive
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "X = 1\n")
      File.write(File.join(dir, "b.rb"), "X = 1\n") # identical content, other path
      m1 = Mutineer::CoverageMap.new(source_paths: ["a.rb"], test_paths: [], cache_dir: dir, project_root: dir)
      m2 = Mutineer::CoverageMap.new(source_paths: ["b.rb"], test_paths: [], cache_dir: dir, project_root: dir)
      refute_equal m1.send(:compute_digest), m2.send(:compute_digest)
    end
  end

  def test_digest_is_role_sensitive
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "x.rb"), "X = 1\n")
      File.write(File.join(dir, "y.rb"), "Y = 2\n")
      m1 = Mutineer::CoverageMap.new(source_paths: ["x.rb"], test_paths: ["y.rb"], cache_dir: dir, project_root: dir)
      m2 = Mutineer::CoverageMap.new(source_paths: ["y.rb"], test_paths: ["x.rb"], cache_dir: dir, project_root: dir)
      refute_equal m1.send(:compute_digest), m2.send(:compute_digest)
    end
  end

  # --- R7: source outside project root warns -------------------------------

  def test_source_outside_project_root_warns
    Dir.mktmpdir do |dir|
      sub = File.join(dir, "proj")
      FileUtils.mkdir_p(sub)
      File.write(File.join(dir, "outside.rb"), "Z = 1\n")
      _, err = capture_subprocess_io do
        Mutineer::CoverageMap.new(source_paths: ["../outside.rb"], test_paths: [],
                                cache_dir: Dir.mktmpdir, project_root: sub).build_or_load
      end
      assert_includes err, "outside project root"
    end
  end

  # --- R6/cache: a cache HIT with recorded failures must still warn ---------

  # #97: a required helper is not part of the source/test digest, but changing it
  # must rebuild the map so newly covered branches are not left as no_coverage.
  def test_required_helper_change_invalidates_cache
    Dir.mktmpdir("mutineer-helper-cache") do |dir|
      src    = File.join(dir, "calculator.rb")
      test   = File.join(dir, "calculator_test.rb")
      helper = File.join(dir, "test_helper.rb")
      cache  = File.join(dir, "cache")
      File.write(src, <<~RUBY)
        class AuditCacheCalculator
          def compute(value)
            if value == 1
              1 + 2
            else
              4 + 5
            end
          end
        end
      RUBY
      File.write(test, <<~RUBY)
        require_relative "test_helper"
        require_relative "calculator"
        class AuditCacheCalculatorTest < Minitest::Test
          def test_compute
            AuditCases::VALUES.each do |value|
              result = AuditCacheCalculator.new.compute(value)
              value == 1 ? assert_equal(3, result) : refute_nil(result)
            end
          end
        end
      RUBY
      write_helper = lambda do |values|
        File.write(helper, "require 'minitest/autorun'\nmodule AuditCases\n  VALUES = #{values.inspect}\nend\n")
      end
      mk = lambda do
        Mutineer::CoverageMap.new(
          source_paths: [src], test_paths: [test],
          cache_dir: cache, project_root: dir
        ).build_or_load
      end

      write_helper.call([1])
      first = nil
      capture_subprocess_io { first = mk.call }
      assert first.phase_a_ran
      else_line = File.read(src)[0...File.read(src).index("4 + 5")].count("\n") + 1
      assert_empty first.tests_for(src, else_line), "else branch starts uncovered"

      write_helper.call([1, 2])
      second = nil
      capture_subprocess_io { second = mk.call }
      assert second.phase_a_ran, "helper change must rebuild the map"
      refute_empty second.tests_for(src, else_line), "else branch is now covered"
    end
  end

  def test_unchanged_helper_still_reuses_cache
    Dir.mktmpdir("mutineer-helper-stable") do |dir|
      src    = File.join(dir, "calculator.rb")
      test   = File.join(dir, "calculator_test.rb")
      helper = File.join(dir, "test_helper.rb")
      cache  = File.join(dir, "cache")
      File.write(src, "class HCalc\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(helper, "require 'minitest/autorun'\n")
      File.write(test, <<~RUBY)
        require_relative "test_helper"
        require_relative "calculator"
        class HCalcTest < Minitest::Test
          def test_add; assert_equal 5, HCalc.new.add(2, 3); end
        end
      RUBY
      mk = lambda do
        Mutineer::CoverageMap.new(
          source_paths: [src], test_paths: [test],
          cache_dir: cache, project_root: dir
        ).build_or_load
      end
      capture_subprocess_io { mk.call }
      second = nil
      capture_subprocess_io { second = mk.call }
      refute second.phase_a_ran, "unchanged helper: cache hit"
    end
  end

  def test_old_cache_without_dependencies_rebuilds
    Dir.mktmpdir("mutineer-old-cache") do |dir|
      src  = File.join(dir, "calculator.rb")
      test = File.join(dir, "calculator_test.rb")
      cache = File.join(dir, "cache")
      File.write(src, "class OldCacheCalc\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(test, <<~RUBY)
        require "minitest/autorun"
        require_relative "calculator"
        class OldCacheCalcTest < Minitest::Test
          def test_add; assert_equal 5, OldCacheCalc.new.add(2, 3); end
        end
      RUBY
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(
          source_paths: [src], test_paths: [test],
          cache_dir: cache, project_root: dir
        ).build_or_load
      end
      assert map.phase_a_ran
      payload = JSON.parse(File.read(File.join(cache, "coverage.json")))
      payload.delete("dependencies")
      File.write(File.join(cache, "coverage.json"), JSON.generate(payload))

      second = nil
      capture_subprocess_io do
        second = Mutineer::CoverageMap.new(
          source_paths: [src], test_paths: [test],
          cache_dir: cache, project_root: dir
        ).build_or_load
      end
      assert second.phase_a_ran, "cache without dependency fingerprints must rebuild"
    end
  end

  def test_cache_hit_with_failed_files_warns
    dir = Dir.mktmpdir("mutineer-cache")
    bad = File.join(Dir.mktmpdir, "broken_test.rb")
    File.write(bad, "require 'does/not/exist'\n")
    capture_subprocess_io { build([STRONG_TEST, bad], cache_dir: dir) } # populate cache

    second = nil
    _, err = capture_subprocess_io { second = build([STRONG_TEST, bad], cache_dir: dir) }
    refute second.phase_a_ran, "second build should be a cache hit"
    assert_includes err, "cached coverage map may be incomplete"
  end

  def test_warm_cache_preloads_sources_for_tests_without_require
    Dir.mktmpdir("mutineer-preload") do |dir|
      src  = File.join(dir, "calc.rb")
      test = File.join(dir, "calc_test.rb")
      cache = File.join(dir, "cache")
      File.write(src, "class PreloadCalc\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(test, <<~RUBY)
        require "minitest/autorun"
        class PreloadCalcTest < Minitest::Test
          def test_add; assert_equal 5, PreloadCalc.new.add(2, 3); end
        end
      RUBY
      mk = lambda do
        Mutineer::CoverageMap.new(
          source_paths: [src], test_paths: [test],
          cache_dir: cache, project_root: dir
        ).build_or_load
      end
      first = nil
      capture_subprocess_io { first = mk.call }
      assert_empty first.failed_clean_tests
      second = nil
      capture_subprocess_io { second = mk.call }
      refute second.phase_a_ran
      assert_empty second.failed_clean_tests
    end
  end

  def test_cache_retries_capture_after_helper_load_error_is_fixed
    Dir.mktmpdir("mutineer-retry-fail") do |dir|
      src    = File.join(dir, "calc.rb")
      test   = File.join(dir, "calc_test.rb")
      helper = File.join(dir, "boom_helper.rb")
      cache  = File.join(dir, "cache")
      File.write(src, "class RetryCalc\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(test, <<~RUBY)
        require_relative "boom_helper"
        require_relative "calc"
        class RetryCalcTest < Minitest::Test
          def test_add; assert_equal 5, RetryCalc.new.add(2, 3); end
        end
      RUBY
      File.write(helper, "raise 'boom helper'\n")
      mk = lambda do
        Mutineer::CoverageMap.new(
          source_paths: [src], test_paths: [test],
          cache_dir: cache, project_root: dir
        ).build_or_load
      end
      first = nil
      capture_subprocess_io { first = mk.call }
      assert_includes first.failed_test_files, "calc_test.rb"

      File.write(helper, "require 'minitest/autorun'\n")
      second = nil
      _out, err = capture_subprocess_io { second = mk.call }
      refute second.phase_a_ran, "fixed helper: must retry from cache, not rebuild"
      refute_includes second.failed_test_files, "calc_test.rb"
      refute_includes err, "cached coverage map may be incomplete"
      refute_empty second.tests_for(src, File.read(src)[0...File.read(src).index("a + b")].count("\n") + 1)
    end
  end

  def test_fork_clean_pass_times_out_instead_of_hanging
    ensure_coverage_running
    hang = File.join(Dir.mktmpdir, "hang_clean_test.rb")
    File.write(hang, "sleep 5\n")
    map = Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: [hang],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, capture_timeout: 0.05
    )
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ok, = map.send(:fork_clean_pass?, [hang], nil)
    refute ok
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 2.0
  end

  def test_clean_pass_reports_a_timeout_apart_from_a_failure
    ensure_coverage_running
    hang = File.join(Dir.mktmpdir, "hang_clean_test.rb")
    File.write(hang, "sleep 5\n")
    map = Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: [hang],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, capture_timeout: 0.05
    )
    _ok, _report, timed_out = map.send(:fork_clean_pass?, [hang], nil)
    assert timed_out, "fork clean check past its deadline"
    _ok, _report, timed_out = map.send(:subprocess_clean_pass?, [hang])
    assert timed_out, "subprocess clean check past its deadline"
  end

  # The combined check runs every file in one process, so its deadline follows
  # the measured capture time, never below --capture-timeout.
  def test_combined_clean_timeout_scales_with_capture_timings
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT, capture_timeout: 120)
    map.timings.merge!("a_test.rb" => 70.0, "b_test.rb" => 50.2, "skipped_test.rb" => 500.0)
    assert_equal 181, map.send(:combined_clean_timeout, %w[a_test.rb b_test.rb])
    assert_equal 120, map.send(:combined_clean_timeout, %w[a_test.rb])
    assert_equal 120, map.send(:combined_clean_timeout, %w[new_test.rb])
  end

  def test_combined_clean_check_records_a_timeout_not_a_failure
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT, capture_timeout: 120)
    map.define_singleton_method(:clean_check_test_paths) { %w[a_test.rb b_test.rb] }
    used = nil
    map.define_singleton_method(:subprocess_clean_pass?) do |_paths, timeout:|
      used = timeout
      [false, "", true]
    end
    map.send(:verify_combined_clean)
    assert_equal 120, used
    assert_equal ["combined suite"], map.failed_clean_tests
    assert_equal({ "combined suite" => 120 }, map.clean_timeouts)
    assert_nil map.failed_clean_details["combined suite"]
  end

  # Summed timings above --capture-timeout: the check must get 1.5 times the
  # sum, rounded up, so a wrong factor or a missing file's timing fails here.
  def test_combined_clean_check_forwards_the_scaled_deadline
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT, capture_timeout: 120)
    map.timings.merge!("a_test.rb" => 100.0, "b_test.rb" => 60.1)
    map.define_singleton_method(:clean_check_test_paths) { %w[a_test.rb b_test.rb] }
    used = nil
    map.define_singleton_method(:subprocess_clean_pass?) do |_paths, timeout:|
      used = timeout
      [false, "", true]
    end
    map.send(:verify_combined_clean)
    assert_equal 241, used
    assert_equal({ "combined suite" => 241 }, map.clean_timeouts)
  end

  # Boot mode (--daemon builds through build_via_fork) runs the combined check
  # in a fork, which must get the same scaled deadline.
  def test_combined_clean_check_forwards_the_scaled_deadline_to_the_fork
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT,
                                    capture_timeout: 120, boot_path: "boot.rb")
    map.timings.merge!("a_test.rb" => 100.0, "b_test.rb" => 60.1)
    map.define_singleton_method(:clean_check_test_paths) { %w[a_test.rb b_test.rb] }
    map.define_singleton_method(:subprocess_clean_pass?) { |*, **| flunk "boot mode must fork" }
    used = nil
    map.define_singleton_method(:fork_clean_pass?) do |_abs, _after_fork, timeout:|
      used = timeout
      [false, "", true]
    end
    map.send(:verify_combined_clean)
    assert_equal 241, used
    assert_equal({ "combined suite" => 241 }, map.clean_timeouts)
  end

  # Every return of the clean-pass helpers has the documented three elements,
  # with an explicit false when the deadline did not pass.
  def test_clean_pass_helpers_return_three_elements_on_every_branch
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT)
    status = Object.new
    def status.success? = true
    line = "not-json"
    map.define_singleton_method(:spawn_script) { |*, **| [status, line] }
    assert_equal [false, "", false], map.send(:subprocess_clean_pass?, [])
    line = JSON.generate("passed" => true, "failure_report" => "")
    assert_equal [true, "", false], map.send(:subprocess_clean_pass?, [])

    payload = nil
    map.define_singleton_method(:fork) { |*| 0 }
    map.define_singleton_method(:await_child) { |*| [status, payload] }
    assert_equal [false, "", false], map.send(:fork_clean_pass?, [], nil)
    payload = [true, ""]
    assert_equal [true, "", false], map.send(:fork_clean_pass?, [], nil)
    map.define_singleton_method(:await_child) { |*| raise IOError, "pipe" }
    assert_equal [false, "", false], map.send(:fork_clean_pass?, [], nil)
  end

  def test_cached_clean_check_records_a_timeout_not_a_failure
    map = Mutineer::CoverageMap.new(source_paths: [], test_paths: [], project_root: ROOT, capture_timeout: 120)
    map.define_singleton_method(:subprocess_clean_pass?) { |paths| paths == ["slow_test.rb"] ? [false, "", true] : [false, "boom", false] }
    map.send(:verify_cached_clean, test_paths: %w[slow_test.rb red_test.rb])
    assert_equal %w[slow_test.rb red_test.rb], map.failed_clean_tests
    assert_equal({ "slow_test.rb" => 120 }, map.clean_timeouts)
    assert_equal "boom", map.failed_clean_details["red_test.rb"]
  end

  # --- #101 / #129: one deadline for the whole capture ----------------------

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # True once `pid` no longer runs. An orphan can stay a zombie for a moment
  # until init reaps it, so a zombie counts as gone.
  def process_gone?(pid)
    Process.kill(0, pid)
    `ps -o stat= -p #{pid}`.strip.start_with?("Z")
  rescue Errno::ESRCH
    true
  end

  def assert_process_gone(pid)
    gone = false
    50.times { (gone = process_gone?(pid)) ? break : sleep(0.1) } # rubocop:disable Style/Semicolon
    assert gone, "process #{pid} survived the capture"
  end

  # #101: a hung test in a forked (--boot / --daemon) capture stops at
  # capture_timeout instead of blocking the run.
  def test_fork_capture_times_out_instead_of_hanging
    ensure_coverage_running
    hang = File.join(Dir.mktmpdir, "hang_capture_test.rb")
    File.write(hang, "sleep 10\n")
    map = Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: [hang],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, capture_timeout: 0.3
    )
    started = monotonic
    _, err = capture_subprocess_io { map.send(:run_phase_a_via_fork, after_fork: nil) }
    assert_operator monotonic - started, :<, 5.0
    assert_equal ["hang_capture_test.rb"], map.failed_test_files.map { |f| File.basename(f) }
    assert_includes err, "timed out after 0.3s"
  end

  # A process the test leaves behind inherits the result pipe across fork, and
  # setsid takes it out of the capture's process group. The capture must not
  # wait for it to exit before it reads the result.
  def test_fork_capture_does_not_wait_for_a_process_that_holds_the_pipe
    ensure_coverage_running
    dir = Dir.mktmpdir
    pid_file = File.join(dir, "pid")
    test = File.join(dir, "leftover_capture_test.rb")
    File.write(test, <<~RUBY)
      require "minitest"
      File.write(#{pid_file.inspect}, fork { Process.setsid; sleep 30; exit!(0) }.to_s)
      class LeftoverCaptureTest < Minitest::Test
        def test_add = assert_equal(5, Calculator.new.add(2, 3))
      end
    RUBY
    map = fork_map(test, verbose: true)
    started = monotonic
    payload = map.send(:fork_capture, test, [CALC], nil)
    assert_operator monotonic - started, :<, 15.0, "capture waited for the leftover process"
    assert_kind_of Hash, payload
    assert payload["passed"]
  ensure
    Process.kill(:KILL, File.read(pid_file).to_i) rescue nil if pid_file && File.exist?(pid_file) # rubocop:disable Style/RescueModifier
  end

  # On timeout the capture stops the test's whole process group, not only the
  # `ruby` it spawned.
  def test_capture_timeout_stops_processes_the_test_started
    dir = Dir.mktmpdir
    pid_file = File.join(dir, "pid")
    hang = File.join(dir, "hang_with_child_test.rb")
    File.write(hang, "File.write(#{pid_file.inspect}, fork { sleep 30; exit!(0) }.to_s)\nsleep 30\n")
    map = nil
    capture_subprocess_io do
      map = Mutineer::CoverageMap.new(
        source_paths: [CALC], test_paths: [hang],
        cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, capture_timeout: 3
      ).build_or_load
    end
    assert_includes map.failed_test_files.map { |f| File.basename(f) }, "hang_with_child_test.rb"
    assert File.exist?(pid_file), "the test did not start its child before the timeout"
    assert_process_gone(File.read(pid_file).to_i)
  ensure
    Process.kill(:KILL, File.read(pid_file).to_i) rescue nil if pid_file && File.exist?(pid_file) # rubocop:disable Style/RescueModifier
  end

  # #129: the child exits before the deadline, but the thread that reads its
  # result has not finished when the deadline passes. The result must still
  # count; it is already in the pipe. The stubs put the deadline right at the
  # child exit and slow the reader, so the edge happens every run.
  def test_capture_keeps_a_result_the_reader_finishes_after_the_deadline
    map = Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: [STRONG_TEST],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    calls = 0
    map.define_singleton_method(:remaining) { |deadline| (calls += 1) == 1 ? super(deadline) : 0 }
    map.define_singleton_method(:read_result_line) { |io| super(io).tap { sleep 0.2 } }
    payload = nil
    _, err = capture_subprocess_io { payload = map.send(:capture, STRONG_TEST) }
    assert_kind_of Hash, payload, err
    assert payload["passed"]
  end

  # A result read slower than RESULT_GRACE still counts while capture time is
  # left: the grace is a floor, not a cap.
  def test_capture_keeps_a_slow_result_read_with_time_left
    map = Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: [STRONG_TEST],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    map.define_singleton_method(:read_result_line) { |io| super(io).tap { sleep 1.5 } }
    payload = nil
    _, err = capture_subprocess_io { payload = map.send(:capture, STRONG_TEST) }
    assert_kind_of Hash, payload, err
  end

  # A child that exits before reading its script must not raise EPIPE out of
  # spawn_script (and skip the reaper): the capture reports a failed run.
  def test_spawn_script_survives_a_child_that_exits_before_reading
    map = Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: [STRONG_TEST],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    original = RbConfig.method(:ruby)
    RbConfig.define_singleton_method(:ruby) { "false" }
    status, out = map.send(:spawn_script, "#" * 1_000_000)
    refute_predicate status, :success?
    assert_equal "", out
  ensure
    RbConfig.define_singleton_method(:ruby, original) if original
  end

  def test_combined_clean_fails_when_files_pass_alone
    Dir.mktmpdir("mutineer-combined") do |dir|
      src  = File.join(dir, "calc.rb")
      a    = File.join(dir, "a_test.rb")
      b    = File.join(dir, "b_test.rb")
      File.write(src, "class CombinedCalc\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(a, <<~RUBY)
        require "minitest/autorun"
        require_relative "calc"
        $combined_seen = true
        class CombinedATest < Minitest::Test
          def test_add; assert_equal 5, CombinedCalc.new.add(2, 3); end
        end
      RUBY
      File.write(b, <<~RUBY)
        require "minitest/autorun"
        require_relative "calc"
        class CombinedBTest < Minitest::Test
          def test_isolated; refute defined?($combined_seen) && $combined_seen; end
        end
      RUBY
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(
          source_paths: [src], test_paths: [a, b],
          cache_dir: File.join(dir, "cache"), project_root: dir
        ).build_or_load
      end
      assert_includes map.failed_clean_tests, "combined suite"
    end
  end

  def test_failing_test_prefix_file_marks_its_source_uncapturable
    bad = File.join(Dir.mktmpdir, "test_calculator.rb")
    File.write(bad, "require 'does/not/exist'\n")
    map = nil
    capture_subprocess_io { map = build([bad]) }
    assert map.uncapturable_source?(CALC)
  end

  def test_failing_test_with_both_affixes_pairs_by_its_suffix
    bad = File.join(Dir.mktmpdir, "test_calculator_test.rb") # pairs with test_calculator.rb
    File.write(bad, "require 'does/not/exist'\n")
    map = nil
    capture_subprocess_io { map = build([bad]) }
    refute map.uncapturable_source?(CALC)
  end

  # #87: a failed split file in the mirrored directory taints that source
  # when no longer source file owns the name.
  def test_failing_split_test_marks_the_shorter_source_uncapturable
    dir = Dir.mktmpdir
    src = File.join(dir, "app/foo/bar.rb")
    bad = File.join(dir, "test/foo/bar_upsert_test.rb")
    FileUtils.mkdir_p(File.dirname(src))
    FileUtils.mkdir_p(File.dirname(bad))
    File.write(src, "class Bar; def n; 1; end; end\n")
    File.write(bad, "require 'does/not/exist'\n")
    map = nil
    capture_subprocess_io do
      map = Mutineer::CoverageMap.new(source_paths: [src], test_paths: [bad],
                                      cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
    end
    assert map.uncapturable_source?(src)
  end

  # A failed exact spec in the mirrored directory marks that app source.
  def test_failing_exact_spec_in_the_mirror_marks_the_source_uncapturable
    Dir.mktmpdir do |dir|
      src = File.join(dir, "app/foo/bar.rb")
      bad = File.join(dir, "spec/foo/bar_spec.rb")
      FileUtils.mkdir_p(File.dirname(src))
      FileUtils.mkdir_p(File.dirname(bad))
      File.write(src, "class Bar; def n; 1; end; end\n")
      File.write(bad, "require 'does/not/exist'\n")
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(source_paths: [src], test_paths: [bad],
                                        cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      assert map.uncapturable_source?(src)
    end
  end

  # The same basename under another spec directory does not mark the source.
  def test_failing_exact_spec_outside_the_mirror_does_not_taint_the_source
    Dir.mktmpdir do |dir|
      src = File.join(dir, "app/foo/bar.rb")
      bad = File.join(dir, "spec/other/bar_spec.rb")
      FileUtils.mkdir_p(File.dirname(src))
      FileUtils.mkdir_p(File.dirname(bad))
      File.write(src, "class Bar; def n; 1; end; end\n")
      File.write(bad, "require 'does/not/exist'\n")
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(source_paths: [src], test_paths: [bad],
                                        cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      refute map.uncapturable_source?(src)
    end
  end

  # lib/ sources also accept the spec/lib mirror.
  def test_failing_exact_spec_under_spec_lib_marks_a_lib_source
    Dir.mktmpdir do |dir|
      src = File.join(dir, "lib/billing/invoice.rb")
      bad = File.join(dir, "spec/lib/billing/invoice_spec.rb")
      FileUtils.mkdir_p(File.dirname(src))
      FileUtils.mkdir_p(File.dirname(bad))
      File.write(src, "class Invoice; def n; 1; end; end\n")
      File.write(bad, "require 'does/not/exist'\n")
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(source_paths: [src], test_paths: [bad],
                                        cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      assert map.uncapturable_source?(src)
    end
  end

  # test/foo/bar_upsert_test.rb is an exact name for bar_upsert.rb, but only
  # in the foo mirror. A source in another directory must stay no_coverage.
  def test_failed_exact_name_in_another_mirror_does_not_taint_that_source
    dir = Dir.mktmpdir
    other = File.join(dir, "app/other/bar_upsert.rb")
    bad = File.join(dir, "test/foo/bar_upsert_test.rb")
    FileUtils.mkdir_p(File.dirname(other))
    FileUtils.mkdir_p(File.dirname(bad))
    File.write(other, "class BarUpsert; def n; 1; end; end\n")
    File.write(bad, "require 'does/not/exist'\n")
    map = nil
    capture_subprocess_io do
      map = Mutineer::CoverageMap.new(source_paths: [other], test_paths: [bad],
                                      cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
    end
    refute map.uncapturable_source?(other)
  end

  # A failed exact namespace test marks the concern. A spec does the same.
  def test_failing_namespace_test_marks_the_concern_uncapturable
    [
      "test/models/storage/totaled_test.rb",
      "spec/models/storage/totaled_spec.rb"
    ].each do |test_rel|
      Dir.mktmpdir do |dir|
        map, src = concern_namespace_capture(dir, test_rel)
        assert map.uncapturable_source?(src), test_rel
        assert map.method_uncapturable?(src, 3..5), test_rel
      end
    end
  end

  # The same name outside both mirrors does not mark the concern.
  def test_failing_same_name_outside_both_mirrors_does_not_taint_the_concern
    Dir.mktmpdir do |dir|
      map, src = concern_namespace_capture(dir, "test/models/other/totaled_test.rb")
      refute map.uncapturable_source?(src)
      refute map.method_uncapturable?(src, 3..5)
    end
  end

  # A failed split name at the namespace path marks the concern.
  def test_failing_split_name_at_the_namespace_path_marks_the_concern
    Dir.mktmpdir do |dir|
      map, src = concern_namespace_capture(dir, "test/models/storage/totaled_bytes_test.rb")
      assert map.uncapturable_source?(src)
      assert map.method_uncapturable?(src, 3..5)
    end
  end

  # A longer model owns the namespace split, so the failed file does not mark
  # the concern. The model is the source that pairs with the file.
  def test_failing_namespace_split_owned_by_a_longer_model_does_not_taint_the_concern
    Dir.mktmpdir do |dir|
      longer = File.join(dir, "app/models/storage/totaled_bytes.rb")
      FileUtils.mkdir_p(File.dirname(longer))
      File.write(longer, "class TotaledBytes; def n; 1; end; end\n")
      map, src = concern_namespace_capture(dir, "test/models/storage/totaled_bytes_test.rb")
      refute map.uncapturable_source?(src)
      refute map.method_uncapturable?(src, 3..5)
      assert map.uncapturable_source?(longer)
    end
  end

  # A namespace spec leaves split names unpaired. A failed split must not
  # mark the concern when that spec is the paired file.
  def test_failing_namespace_split_does_not_taint_a_concern_paired_with_a_spec
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "spec/models/storage/totaled_spec.rb")
      FileUtils.mkdir_p(File.dirname(spec))
      File.write(spec, "# spec\n")
      map, src = concern_namespace_capture(dir, "test/models/storage/totaled_bytes_test.rb")
      refute map.uncapturable_source?(src)
      refute map.method_uncapturable?(src, 3..5)
    end
  end

  # The longer concern already has a concerns-path test, so it does not run
  # the namespace split. A failed copy marks the shorter concern, which does.
  def test_failing_namespace_split_marks_the_shorter_concern_when_the_longer_one_has_its_own_test
    Dir.mktmpdir do |dir|
      shorter = "app/models/concerns/user.rb"
      longer_rel = "app/models/concerns/user_session.rb"
      own = "test/models/concerns/user_session_test.rb"
      bad_rel = "test/models/user_session_extra_test.rb"
      [shorter, longer_rel, own].each do |rel|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "module M; def n; 1; end; end\n")
      end
      bad = File.join(dir, bad_rel)
      FileUtils.mkdir_p(File.dirname(bad))
      File.write(bad, "require 'does/not/exist'\n")
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(
          source_paths: [File.join(dir, shorter), File.join(dir, longer_rel)],
          test_paths: [bad],
          cache_dir: File.join(dir, "cache"), project_root: dir
        ).build_or_load
      end
      assert map.uncapturable_source?(File.join(dir, shorter))
      refute map.uncapturable_source?(File.join(dir, longer_rel))
    end
  end

  # A longer concern owns the namespace split. The shorter concern stays a
  # coverage gap. The longer concern is the one the failed file marks.
  def test_failing_namespace_split_owned_by_a_longer_concern_marks_that_concern
    Dir.mktmpdir do |dir|
      shorter = "app/models/concerns/user.rb"
      longer_rel = "app/models/concerns/user_session.rb"
      bad_rel = "test/models/user_session_extra_test.rb"
      [shorter, longer_rel, bad_rel].each do |rel|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, rel == bad_rel ? "require 'does/not/exist'\n" : "module M; def n; 1; end; end\n")
      end
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(
          source_paths: [File.join(dir, shorter), File.join(dir, longer_rel)],
          test_paths: [File.join(dir, bad_rel)],
          cache_dir: File.join(dir, "cache"), project_root: dir
        ).build_or_load
      end
      refute map.uncapturable_source?(File.join(dir, shorter))
      assert map.uncapturable_source?(File.join(dir, longer_rel))
    end
  end

  # A test at the concerns path wins, so a failed namespace test does not
  # mark the concern. Pairing would not run the namespace test for it.
  # An exact name and a split name at the namespace path follow the same rule.
  def test_failing_namespace_test_does_not_taint_a_concern_with_its_own_test
    %w[test/models/storage/totaled_test.rb
       test/models/storage/totaled_bytes_test.rb].each do |failed|
      %w[test/models/concerns/storage/totaled_test.rb
         test/models/concerns/storage/totaled_sum_test.rb].each do |own|
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, File.dirname(own)))
          File.write(File.join(dir, own), "# exists\n")
          map, src = concern_namespace_capture(dir, failed)
          refute map.uncapturable_source?(src), "#{own} vs #{failed}"
          refute map.method_uncapturable?(src, 3..5), "#{own} vs #{failed}"
        end
      end
    end
  end

  # Build a concern whose named test fails to load.
  def concern_namespace_capture(dir, test_rel)
    source = "app/models/concerns/storage/totaled.rb"
    src = File.join(dir, source)
    bad = File.join(dir, test_rel)
    FileUtils.mkdir_p(File.dirname(src))
    FileUtils.mkdir_p(File.dirname(bad))
    File.write(src, "module Storage\n  module Totaled\n    def total(a, b)\n      a + b\n    end\n  end\nend\n")
    File.write(bad, "require 'does/not/exist'\n")
    map = nil
    capture_subprocess_io do
      map = Mutineer::CoverageMap.new(source_paths: [src], test_paths: [bad],
                                      cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
    end
    [map, src]
  end

  # A failed test in another directory shares a basename prefix only. It must
  # not fail the gate for app/models/user.rb.
  def test_failing_split_test_outside_the_mirror_does_not_taint_the_source
    dir = Dir.mktmpdir
    src = File.join(dir, "app/models/user.rb")
    bad = File.join(dir, "test/mailers/user_admin_test.rb")
    FileUtils.mkdir_p(File.dirname(src))
    FileUtils.mkdir_p(File.dirname(bad))
    File.write(src, "class User; def n; 1; end; end\n")
    File.write(bad, "require 'does/not/exist'\n")
    map = nil
    capture_subprocess_io do
      map = Mutineer::CoverageMap.new(source_paths: [src], test_paths: [bad],
                                      cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
    end
    refute map.uncapturable_source?(src)
  end

  # src/user_session.rb owns the split name even though it is outside app/ and lib/.
  def test_failing_split_owned_outside_app_and_lib_does_not_taint_the_shorter_source
    dir = Dir.mktmpdir
    user = File.join(dir, "src/user.rb")
    session = File.join(dir, "src/user_session.rb")
    bad = File.join(dir, "test/src/user_session_test.rb")
    [user, session, bad].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
    File.write(user, "class User; def n; 1; end; end\n")
    File.write(session, "class UserSession; def n; 1; end; end\n")
    File.write(bad, "require 'does/not/exist'\n")
    map = nil
    capture_subprocess_io do
      map = Mutineer::CoverageMap.new(source_paths: [user, session], test_paths: [bad],
                                      cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
    end
    assert map.uncapturable_source?(session)
    refute map.uncapturable_source?(user)
  end

  # The blame decision is fixed for this map. Deleting the longer source
  # during the run must not move the stored failure onto user.rb.
  def test_deleting_a_longer_source_during_the_run_does_not_retarget_the_failure
    Dir.mktmpdir do |dir|
      user = File.join(dir, "app/models/user.rb")
      session = File.join(dir, "app/models/user_session.rb")
      bad = File.join(dir, "test/models/user_session_extra_test.rb")
      [user, session, bad].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
      File.write(user, "class User; def n; 1; end; end\n")
      File.write(session, "class UserSession; def n; 1; end; end\n")
      File.write(bad, "require 'does/not/exist'\n")
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(source_paths: [user], test_paths: [bad],
                                        cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      refute map.uncapturable_source?(user)

      File.delete(session)
      refute map.uncapturable_source?(user)
    end
  end

  # The next run sees the deleted sibling. The test passes once that file is
  # gone, so user.rb stays a coverage gap instead of a stored failure.
  def test_deleting_a_longer_source_rebuilds_coverage
    Dir.mktmpdir do |dir|
      user = File.join(dir, "app/models/user.rb")
      session = File.join(dir, "app/models/user_session.rb")
      bad = File.join(dir, "test/models/user_session_extra_test.rb")
      [user, session, bad].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
      File.write(user, "class User; def n; 1; end; end\n")
      File.write(session, "class UserSession; def n; 1; end; end\n")
      File.write(bad, <<~RUBY)
        sibling = File.expand_path("../../app/models/user_session.rb", __dir__)
        raise "sibling present" if File.file?(sibling)
      RUBY
      first = nil
      capture_subprocess_io do
        first = Mutineer::CoverageMap.new(source_paths: [user], test_paths: [bad],
                                          cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      refute_empty first.failed_test_files
      refute first.uncapturable_source?(user)

      File.write(session, "class UserSession; def n; 2; end; end\n")
      edited = nil
      capture_subprocess_io do
        edited = Mutineer::CoverageMap.new(source_paths: [user], test_paths: [bad],
                                           cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      refute edited.phase_a_ran, "a sibling content edit does not change pairing"

      File.delete(session)
      rebuilt = nil
      capture_subprocess_io do
        rebuilt = Mutineer::CoverageMap.new(source_paths: [user], test_paths: [bad],
                                            cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      assert rebuilt.phase_a_ran, "deleting the longer source must rebuild coverage"
      refute rebuilt.uncapturable_source?(user)
    end
  end

  # A longer file in the namespace directory owns the concern's split name.
  # Deleting it changes the digest, so the next run captures again.
  def test_deleting_a_namespace_longer_source_rebuilds_a_concern
    Dir.mktmpdir do |dir|
      concern = File.join(dir, "app/models/concerns/storage/totaled.rb")
      longer = File.join(dir, "app/models/storage/totaled_bytes.rb")
      bad = File.join(dir, "test/models/storage/totaled_bytes_extra_test.rb")
      [concern, longer, bad].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
      File.write(concern, "module Storage\n  module Totaled\n    def total(a, b)\n      a + b\n    end\n  end\nend\n")
      File.write(longer, "class TotaledBytes; def n; 1; end; end\n")
      File.write(bad, <<~RUBY)
        sibling = File.expand_path("../../../app/models/storage/totaled_bytes.rb", __dir__)
        raise "sibling present" if File.file?(sibling)
      RUBY
      first = nil
      capture_subprocess_io do
        first = Mutineer::CoverageMap.new(source_paths: [concern], test_paths: [bad],
                                          cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      refute_empty first.failed_test_files
      refute first.uncapturable_source?(concern)

      File.delete(longer)
      refute first.uncapturable_source?(concern), "the stored blame stays with this map"

      rebuilt = nil
      capture_subprocess_io do
        rebuilt = Mutineer::CoverageMap.new(source_paths: [concern], test_paths: [bad],
                                            cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      assert rebuilt.phase_a_ran, "deleting the namespace owner must rebuild coverage"
      refute rebuilt.uncapturable_source?(concern)
    end
  end

  # The daemon rebuilds the map with from_data, which has no @source_paths.
  # A failed exact test must still blame its source, and must not raise.
  def test_from_data_uncapturable_does_not_crash_without_source_paths
    map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: ["test/calc_test.rb"],
                                          project_root: Dir.pwd)
    assert map.method_uncapturable?("lib/calc.rb", 1..3)
  end

  # The split path must run on a daemon map. An exact name returns before it.
  # The files exist so path normalization stays project-relative.
  def test_from_data_split_blame_does_not_need_source_paths
    Dir.mktmpdir do |dir|
      bad = File.join(dir, "test/foo/bar_extra_test.rb")
      src = File.join(dir, "app/foo/bar.rb")
      FileUtils.mkdir_p(File.dirname(bad))
      FileUtils.mkdir_p(File.dirname(src))
      File.write(bad, "require 'does/not/exist'\n")
      File.write(src, "class Bar; def n; 1; end; end\n")
      map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: ["test/foo/bar_extra_test.rb"],
                                            project_root: dir)
      assert map.method_uncapturable?(src, 3..5)
    end
  end

  # user_mailer_test.rb keeps its exact source. It must not also fail the gate
  # for uncovered methods in user.rb while user_mailer.rb is in the run.
  def test_failing_longer_name_does_not_taint_a_shorter_source_also_in_the_run
    dir = Dir.mktmpdir
    user = File.join(dir, "user.rb")
    mailer = File.join(dir, "user_mailer.rb")
    File.write(user, "class User; def n; 1; end; end\n")
    File.write(mailer, "class UserMailer; def n; 1; end; end\n")
    bad = File.join(dir, "user_mailer_test.rb")
    File.write(bad, "require 'does/not/exist'\n")
    map = nil
    capture_subprocess_io do
      map = Mutineer::CoverageMap.new(source_paths: [user, mailer], test_paths: [bad],
                                      cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
    end
    assert map.uncapturable_source?(mailer)
    refute map.uncapturable_source?(user)
  end

  def test_failing_test_helper_does_not_taint_a_helper_source
    dir = Dir.mktmpdir
    helper = File.join(dir, "helper.rb")
    File.write(helper, "class Helper; end\n")
    bad = File.join(dir, "test_helper.rb")
    File.write(bad, "require 'does/not/exist'\n")
    map = nil
    capture_subprocess_io do
      map = Mutineer::CoverageMap.new(source_paths: [helper], test_paths: [bad],
                                      cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
    end
    refute map.uncapturable_source?(helper)
  end

  def test_capture_and_clean_check_run_a_source_once
    Dir.mktmpdir do |dir|
      src = File.join(dir, "once.rb")
      File.write(src, "$loads = ($loads || 0) + 1\nclass Once\n  def one = 1\nend\n")
      File.write(File.join(dir, "once_test.rb"), "require 'minitest/autorun'\nrequire_relative 'once'\n" \
                 "class OnceTest < Minitest::Test\n  def test_once = assert_equal(1, $loads)\nend\n")
      File.write(File.join(dir, "once_spec.rb"), "require_relative 'once'\n" \
                 "RSpec.describe(Once) { it { expect($loads).to eq(1) } }\n")
      { "minitest" => "once_test.rb", "rspec" => "once_spec.rb" }.each do |framework, test|
        2.times do |run| # the first run captures coverage, the second hits the cache and runs the clean check
          map = Mutineer::CoverageMap.new(source_paths: [src], test_paths: [File.join(dir, test)], framework: framework,
                                          cache_dir: File.join(dir, "cache-#{framework}"), project_root: dir).build_or_load
          assert_equal run.zero?, map.phase_a_ran, framework
          assert_empty map.failed_test_files, framework
          assert_empty map.failed_clean_tests, framework
        end
      end
    end
  end

  # --- #494 pack sources ------------------------------------------------------

  # A failed split test inside a pack marks its pack source. A source of the
  # same name in another directory of the pack (app/services/item.rb) does
  # not take it: the split sits in the mirror of app/models only.
  def test_failing_pack_split_test_marks_only_its_pack_source
    Dir.mktmpdir do |dir|
      src = File.join(dir, "packs/catalog/app/models/item.rb")
      other = File.join(dir, "packs/catalog/app/services/item.rb")
      bad = File.join(dir, "packs/catalog/test/models/item_upsert_test.rb")
      [src, other, bad].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
      File.write(src, "class Item; def n; 1; end; end\n")
      File.write(other, "class ServiceItem; def n; 1; end; end\n")
      File.write(bad, "require 'does/not/exist'\n")
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(source_paths: [src, other], test_paths: [bad],
                                        cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      assert map.uncapturable_source?(src)
      refute map.uncapturable_source?(other)
    end
  end

  # cubic on #557 (#554 item 5): a failed exact test blames a pack source only
  # when pairing gives it that test. A same-named test in another pack, or at
  # the project root that does not mirror the pack path, does not mark it.
  def test_failing_exact_test_in_another_pack_does_not_mark_a_pack_source
    Dir.mktmpdir do |dir|
      mine = File.join(dir, "packs/catalog/app/models/item.rb")
      own_test = File.join(dir, "packs/catalog/test/models/item_test.rb")
      other = File.join(dir, "packs/billing/test/models/item_test.rb")
      [mine, own_test, other].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
      File.write(mine, "class Item; def n; 1; end; end\n")
      File.write(other, "require 'does/not/exist'\n")
      map = nil
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(source_paths: [mine], test_paths: [other],
                                        cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      refute map.uncapturable_source?(mine), "another pack's item_test.rb must not mark this pack's item.rb"

      File.write(own_test, "require 'does/not/exist'\n")
      FileUtils.rm_rf(File.join(dir, "cache"))
      capture_subprocess_io do
        map = Mutineer::CoverageMap.new(source_paths: [mine], test_paths: [own_test],
                                        cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      end
      assert map.uncapturable_source?(mine), "its own failed pack test still marks it"
    end
  end

  # A longer file in another root of the pack can own a split name of a pack
  # source, so its presence changes the digest. A source outside packs/ keeps
  # the digest it had.
  def test_digest_of_a_pack_source_sees_a_longer_file_in_its_pack
    Dir.mktmpdir do |dir|
      pack_src = "packs/catalog/app/models/item.rb"
      plain_src = "app/models/item.rb"
      [pack_src, plain_src].each do |rel|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), "class Item; end\n")
      end
      digest = lambda do |src|
        Mutineer::CoverageMap.new(source_paths: [src], test_paths: [], cache_dir: dir, project_root: dir)
                             .send(:compute_digest)
      end
      before_pack = digest.call(pack_src)
      before_plain = digest.call(plain_src)
      longer = File.join(dir, "packs/catalog/lib/models/item_price.rb")
      FileUtils.mkdir_p(File.dirname(longer))
      File.write(longer, "class ItemPrice; end\n")
      refute_equal before_pack, digest.call(pack_src)
      assert_equal before_plain, digest.call(plain_src)

      # A pack concern also sees a longer file at its namespace path in the pack.
      concern = "packs/catalog/app/models/concerns/storage/totaled.rb"
      FileUtils.mkdir_p(File.dirname(File.join(dir, concern)))
      File.write(File.join(dir, concern), "module Totaled; end\n")
      before_concern = digest.call(concern)
      owner = File.join(dir, "packs/catalog/app/models/storage/totaled_bytes.rb")
      FileUtils.mkdir_p(File.dirname(owner))
      File.write(owner, "class TotaledBytes; end\n")
      refute_equal before_concern, digest.call(concern)
    end
  end

  # The pack test of a pack source runs first for its mutants.
  def test_order_tests_puts_the_pack_test_first
    dir = Dir.mktmpdir("mutineer-order")
    source = "packs/catalog/app/models/item.rb"
    paired = "packs/catalog/test/models/item_test.rb"
    extra = "test/other_test.rb"
    [source, paired, extra].each do |rel|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "")
    end
    timings = { paired => 9.0, extra => 0.1 }
    map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: [], project_root: dir, timings: timings)

    assert_equal [paired, extra], map.order_tests(File.join(dir, source), [extra, paired])
  end
end
