# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
# Pre-require the fixture (R5/KTD4): with it already in $LOADED_FEATURES, the
# test files' `require_relative "calculator"` is a no-op in the child, so the
# child's `load(tempfile)` of the MUTATED source is not clobbered.
require_relative "fixtures/calculator"

class RunnerTest < Minitest::Test
  ROOT        = File.expand_path("..", __dir__)
  CALC        = File.expand_path("fixtures/calculator.rb", __dir__)
  STRONG_TEST = File.expand_path("fixtures/calculator_strong_test.rb", __dir__)
  WEAK_TEST   = File.expand_path("fixtures/calculator_weak_test.rb", __dir__)

  # The `+` in `add`'s body `a + b`. Offsets derived from content (not magic
  # numbers) so the test survives whitespace changes in the fixture.
  def plus_mutation(replacement: "-")
    source = File.read(CALC)
    plus = source.index("a + b") + 2 # skip "a "
    Brutus::Mutation.new(start_offset: plus, end_offset: plus + 1,
                         replacement: replacement, operator: :arithmetic)
  end

  # A CoverageMap built over the fixture and the given test file(s), cached in a
  # throwaway dir so the run is real (Phase A subprocess) but leaves no trace.
  def coverage_map(*test_paths)
    Brutus::CoverageMap.new(
      source_paths: [CALC], test_paths: test_paths,
      cache_dir: Dir.mktmpdir("brutus-cache"), project_root: ROOT
    ).build_or_load
  end

  def test_mutation_killed_by_strong_suite
    result = Brutus::Runner.run(plus_mutation, source_file: CALC, coverage_map: coverage_map(STRONG_TEST))
    assert_predicate result, :killed?, "expected killed, got #{result.status} (#{result.details})"
  end

  def test_mutation_survives_weak_suite
    result = Brutus::Runner.run(plus_mutation, source_file: CALC, coverage_map: coverage_map(WEAK_TEST))
    assert_predicate result, :survived?, "expected survived, got #{result.status} (#{result.details})"
  end

  def test_syntactically_invalid_mutation_is_skipped
    # Replacing `+` with `)` makes `a ) b` — unparseable, so no fork happens.
    result = Brutus::Runner.run(plus_mutation(replacement: ")"),
                                source_file: CALC, coverage_map: coverage_map(STRONG_TEST))
    assert_predicate result, :skipped?, "expected skipped, got #{result.status}"
  end
end
