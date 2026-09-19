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

  def fork_map(test_path, verbose:)
    Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: [test_path],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT, verbose: verbose
    )
  end

  def test_fork_capture_returns_string_diagnostic_for_raising_child
    Coverage.start(lines: true) unless Coverage.running?
    map = fork_map(raising_test, verbose: true)
    payload = map.send(:fork_capture, raising_test, [CALC], nil)
    assert_kind_of String, payload
    assert_match(/RuntimeError: boom from child/, payload)
  end

  # #19: a child that dies WITHOUT writing (hard crash / signal) must yield a
  # diagnostic string naming how it died — not a bare nil/"no result".
  def test_fork_capture_reports_child_death_when_no_output
    Coverage.start(lines: true) unless Coverage.running?
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
    _, exit_st = Process.waitpid2(fork { exit!(3) })
    assert_match(/exit status 3/, map.send(:describe_status, exit_st))
    pid = fork { sleep 5 }
    Process.kill("KILL", pid)
    _, sig_st = Process.waitpid2(pid)
    assert_match(/signal 9/, map.send(:describe_status, sig_st))
  end

  def test_build_via_fork_surfaces_real_error_under_verbose
    Coverage.start(lines: true) unless Coverage.running?
    rt = raising_test
    map = fork_map(rt, verbose: true)
    _, err = capture_subprocess_io { map.build_via_fork(after_fork: nil) }
    assert_match(/boom from child/, err)
    assert_includes map.failed_test_files.map { |f| File.basename(f) }, "raising_test.rb"
  end

  def test_build_via_fork_suppresses_error_without_verbose
    Coverage.start(lines: true) unless Coverage.running?
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

  def test_non_json_subprocess_output_is_skipped_not_fatal
    bad = File.join(Dir.mktmpdir, "noisy_test.rb")
    File.write(bad, %(puts "GARBAGE NOT JSON"\n)) # pollutes stdout before the JSON
    map = nil
    _, err = capture_subprocess_io { map = build([STRONG_TEST, bad]) }
    assert_includes map.failed_test_files.map { |f| File.basename(f) }, "noisy_test.rb"
    assert_includes err, "invalid coverage output"
    refute_empty map.tests_for(CALC, line_of("a + b")), "good test still recorded"
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
      refute_includes second.failed_test_files, "calc_test.rb"
      refute_includes err, "cached coverage map may be incomplete"
      refute_empty second.tests_for(src, File.read(src)[0...File.read(src).index("a + b")].count("\n") + 1)
    end
  end

  def test_fork_clean_pass_times_out_instead_of_hanging
    Coverage.start(lines: true) unless Coverage.running?
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
end
