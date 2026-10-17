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
    end
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
      clean = map.send(:fork_clean_pass?, [noisy], nil)
    end
    assert_kind_of Hash, payload
    assert payload["passed"]
    assert clean
    assert_empty out
  end

  def test_hanging_test_file_times_out_and_is_skipped
    hang = File.join(Dir.mktmpdir, "hang_test.rb")
    File.write(hang, "sleep 30\n")
    map = nil
    capture_subprocess_io do
      map = Mutineer::CoverageMap.new(
        source_paths: [CALC], test_paths: [STRONG_TEST, hang],
        cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, capture_timeout: 0.5
      ).build_or_load
    end
    assert_includes map.failed_test_files.map { |f| File.basename(f) }, "hang_test.rb"
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
    refute map.send(:fork_clean_pass?, [hang], nil)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 2.0
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
      assert map.method_uncapturable?(src, 1..3)
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
end
