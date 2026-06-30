# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "set"
require "stringio"
require "tmpdir"

# #10 acceptance gate: the two suppression mechanisms (inline disable-line comment
# and .mutineer.yml ignore-by-id), the :ignored exclusion from the denominator
# (100% reachable), and the JSON id round-trip. All without Rails, via the library
# API against the standalone fixtures (mirrors integration_test.rb).
class EquivalentMutantTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_mutineer(sources:, tests:, operators: nil, ignore: [])
    config = Mutineer::Config.new(
      sources: sources, tests: tests, operators: operators, ignore: ignore,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    Mutineer::Runner.execute(config)
  end

  # --- suppress_map / suppressed? unit (regex semantics, no fork) ---

  def test_suppress_map_parses_bare_and_scoped
    src = "a + b # mutineer:disable-line\n" \
          "c - d # mutineer:disable-line arithmetic, comparison\n" \
          "e * f\n"
    map = Mutineer::Runner.suppress_map(src)
    assert_equal :all, map[1]
    assert_equal Set[:arithmetic, :comparison], map[2]
    assert_nil map[3]
  end

  def test_suppressed_scope_matches_only_listed_operator
    disabled = { 2 => Set[:comparison] }
    refute Mutineer::Runner.suppressed?(:arithmetic, 2, "id", disabled, Set.new)
    assert Mutineer::Runner.suppressed?(:comparison, 2, "id", disabled, Set.new)
  end

  def test_suppressed_bare_disables_every_operator
    disabled = { 4 => :all }
    assert Mutineer::Runner.suppressed?(:arithmetic, 4, "id", disabled, Set.new)
  end

  def test_suppressed_by_ignore_id
    assert Mutineer::Runner.suppressed?(:arithmetic, 1, "abc123", {}, Set["abc123"])
    refute Mutineer::Runner.suppressed?(:arithmetic, 1, "abc123", {}, Set["other"])
  end

  # --- Acceptance 1: inline disable-line ---

  def test_inline_disable_line_suppresses_and_reaches_100
    agg, = run_mutineer(sources: ["test/fixtures/equivalent.rb"],
                        tests: ["test/fixtures/equivalent_test.rb"],
                        operators: ["arithmetic"])

    assert_equal 0, agg.survived_count, "disable-line mutant must not survive"
    assert_equal 1, agg.ignored_count
    assert_operator agg.killed_count, :>=, 1
    assert_equal 100.0, agg.mutation_score, "suppressing the only survivor reaches 100%"

    ignored = agg.results.select(&:ignored?)
    assert_equal 1, ignored.length
    assert_equal "add", ignored.first.subject.name.to_s
    assert_equal :arithmetic, ignored.first.mutation.operator
    refute(agg.surviving_mutants.any? { |r| r.subject.name.to_s == "add" })
  end

  # --- Acceptance 2 & 3: config ignore-by-id, suppress all -> 100% ---

  def test_config_ignore_id_suppresses_one_survivor
    agg, = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                        tests: ["test/fixtures/calculator_weak_test.rb"])
    assert_equal 2, agg.survived_count
    ids = agg.surviving_mutants.map(&:id)
    assert(ids.all? { |i| i&.length == 12 }, "every survivor carries a stable id")

    agg2, = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                         tests: ["test/fixtures/calculator_weak_test.rb"],
                         ignore: [ids.first])
    assert_equal 1, agg2.survived_count
    assert_equal 1, agg2.ignored_count
    refute_includes agg2.surviving_mutants.map(&:id), ids.first
  end

  def test_suppress_all_survivors_reaches_100
    agg, = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                        tests: ["test/fixtures/calculator_weak_test.rb"])
    ids = agg.surviving_mutants.map(&:id)

    agg2, = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                         tests: ["test/fixtures/calculator_weak_test.rb"],
                         ignore: ids)
    assert_equal 0, agg2.survived_count
    assert_equal 2, agg2.ignored_count
    assert_equal 4, agg2.killed_count
    assert_equal 100.0, agg2.mutation_score
  end

  # --- Acceptance 4: JSON id round-trip ---

  def test_json_survivor_id_round_trips
    agg, source_map = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                                   tests: ["test/fixtures/calculator_weak_test.rb"])
    doc = render_json(agg, source_map)

    assert_equal "1.1", doc["schema_version"]
    assert_equal 2, doc["summary"]["survived"]
    assert_equal 0, doc["summary"]["ignored"]
    ids = doc["survivors"].map { |s| s["id"] }
    assert(ids.all? { |i| i&.length == 12 }, "every JSON survivor has a non-nil id")
    assert(doc["survivors"].all? { |s| s["token"] && !s["token"].empty? })

    agg2, sm2 = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                             tests: ["test/fixtures/calculator_weak_test.rb"],
                             ignore: ids)
    doc2 = render_json(agg2, sm2)
    assert_equal 0, doc2["summary"]["survived"]
    assert_equal 2, doc2["summary"]["ignored"]
    assert_equal ids.sort, doc2["ignored"].map { |s| s["id"] }.sort
    assert_equal [], doc2["survivors"]
  end

  private

  def render_json(agg, source_map)
    out = StringIO.new
    Mutineer::Reporter.new(agg, source_map).report(out: out, err: StringIO.new, format: "json")
    JSON.parse(out.string)
  end
end
