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

  def build(test_paths, cache_dir: Dir.mktmpdir("brutus-cache"))
    Brutus::CoverageMap.new(
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

  # --- Cache: digest, load/save, invalidation ------------------------------

  def test_cache_written_and_reused_without_rerunning_phase_a
    dir = Dir.mktmpdir("brutus-cache")
    first = build([STRONG_TEST], cache_dir: dir)
    assert first.phase_a_ran
    assert_path_exists File.join(dir, "coverage.json")

    second = build([STRONG_TEST], cache_dir: dir)
    refute second.phase_a_ran, "digest matched — Phase A should be skipped"
    assert_equal first.tests_for(CALC, line_of("a + b")),
                 second.tests_for(CALC, line_of("a + b"))
  end

  def test_content_change_invalidates_cache_and_rebuilds
    dir = Dir.mktmpdir("brutus-proj")
    cache = Dir.mktmpdir("brutus-cache")
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
      Brutus::CoverageMap.new(source_paths: [src], test_paths: [test],
                              cache_dir: cache, project_root: dir).build_or_load
    end

    first = mk.call
    assert first.phase_a_ran
    refute mk.call.phase_a_ran, "unchanged files: cache hit"

    File.write(test, File.read(test).sub("test_go", "test_renamed"))
    assert mk.call.phase_a_ran, "test file changed: cache must rebuild"
  end

  def test_corrupt_cache_is_rebuilt
    dir = Dir.mktmpdir("brutus-cache")
    File.write(File.join(dir, "coverage.json"), "{not valid json")
    map = build([STRONG_TEST], cache_dir: dir)
    assert map.phase_a_ran
    refute_empty map.tests_for(CALC, line_of("a + b"))
  end

  # --- Acceptance: runner Phase B selection --------------------------------

  def plus_mutation
    source = File.read(CALC)
    plus = source.index("a + b") + 2
    Brutus::Mutation.new(start_offset: plus, end_offset: plus + 1,
                         replacement: "-", operator: :arithmetic)
  end

  def modulo_mutation
    source = File.read(CALC)
    mod = source.index("a % b") + 2
    Brutus::Mutation.new(start_offset: mod, end_offset: mod + 1,
                         replacement: "*", operator: :arithmetic)
  end

  def test_mutation_on_uncovered_line_is_no_coverage
    map = build([ADD_ONLY_TEST]) # no test exercises #modulo
    result = Brutus::Runner.run(modulo_mutation, source_file: CALC, coverage_map: map)
    assert_predicate result, :no_coverage?, "got #{result.status}"
  end

  def test_mutation_on_covered_line_runs_and_is_killed
    map = build([STRONG_TEST])
    result = Brutus::Runner.run(plus_mutation, source_file: CALC, coverage_map: map)
    assert_predicate result, :killed?, "got #{result.status} (#{result.details})"
  end
end
