# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class ReporterTest < Minitest::Test
  SRC = "class Pricing\n  def total(price)\n    if price >= 100\n    end\n  end\nend\n"
  FILE = "pricing.rb"

  def survivor_result
    def_node = Mutineer::Parser.parse_string(SRC).value.statements.body.first.body.body.first
    subject = Mutineer::Subject.new(file: FILE, namespace: ["Pricing"], name: :total,
                                  singleton: false, def_node: def_node)
    off = SRC.index(">=")
    mutation = Mutineer::Mutation.new(start_offset: off, end_offset: off + 2,
                                    replacement: ">", operator: :comparison)
    Mutineer::Result.survived.with(subject: subject, mutation: mutation)
  end

  def aggregate(results) = Mutineer::AggregateResult.new(results)

  # --- AggregateResult contract ---

  def test_empty_score_is_nil
    agg = aggregate([])
    assert_nil agg.mutation_score
    assert_equal 0, agg.total
  end

  def test_score_excludes_no_coverage
    agg = aggregate([Mutineer::Result.killed, Mutineer::Result.survived,
                     Mutineer::Result.no_coverage, Mutineer::Result.no_coverage])
    assert_equal 50.0, agg.mutation_score
  end

  def test_score_excludes_errored_and_skipped
    agg = aggregate([Mutineer::Result.killed, Mutineer::Result.killed, Mutineer::Result.killed,
                     Mutineer::Result.survived, Mutineer::Result.no_coverage,
                     Mutineer::Result.no_coverage, Mutineer::Result.error, Mutineer::Result.skipped])
    assert_equal 75.0, agg.mutation_score
    assert_equal 8, agg.total
  end

  def test_all_no_coverage_score_nil
    assert_nil aggregate([Mutineer::Result.no_coverage]).mutation_score
  end

  # #9: uncapturable is counted but excluded from the denominator, exactly like
  # no_coverage — adding it must not move the score.
  def test_score_excludes_uncapturable
    agg = aggregate([Mutineer::Result.killed, Mutineer::Result.survived,
                     Mutineer::Result.uncapturable, Mutineer::Result.no_coverage])
    assert_equal 50.0, agg.mutation_score
    assert_equal 1, agg.uncapturable_count
    assert_equal 4, agg.total
  end

  def test_all_uncapturable_score_nil
    assert_nil aggregate([Mutineer::Result.uncapturable]).mutation_score
  end

  # --- exit_code ---

  def test_exit_code_threshold_off
    assert_equal 0, reporter([Mutineer::Result.survived]).exit_code(threshold: 0)
  end

  def test_exit_code_below
    assert_equal 1, reporter([Mutineer::Result.killed, Mutineer::Result.survived]).exit_code(threshold: 80.0)
  end

  def test_exit_code_at_threshold_inclusive
    r = reporter([Mutineer::Result.killed, Mutineer::Result.killed,
                  Mutineer::Result.killed, Mutineer::Result.killed, Mutineer::Result.survived])
    assert_equal 0, r.exit_code(threshold: 80.0) # 80.0 >= 80.0
  end

  def test_exit_code_nil_score_skips_gate
    assert_equal 0, reporter([Mutineer::Result.no_coverage]).exit_code(threshold: 80.0)
  end

  # --- rendering / streams ---

  def test_zero_mutations_message_on_stderr
    out = StringIO.new
    err = StringIO.new
    reporter([]).report(out: out, err: err)
    assert_empty out.string
    assert_includes err.string, "No mutations generated"
  end

  def test_survivor_diff_and_grouping
    out = StringIO.new
    reporter([survivor_result]).report(out: out, err: StringIO.new)
    s = out.string
    assert_includes s, "Pricing#total"
    assert_includes s, "comparison  (>= -> >)"
    # indentation is preserved (conventional diff fidelity)
    assert_includes s, "-     if price >= 100"
    assert_includes s, "+     if price > 100"
    assert_includes s, FILE
  end

  # Regression: a mutation whose byte range spans multiple lines (e.g.
  # statement-removal of a multi-line statement) must render every original line
  # as `-` and the spliced replacement as `+`, with a single-line token label —
  # not a fragment of two lines mashed together.
  def test_multiline_statement_removal_diff_is_not_mangled
    src = "class Foo\n  def bar(x)\n    log(x,\n        y)\n    x + 1\n  end\nend\n"
    def_node = Mutineer::Parser.parse_string(src).value.statements.body.first.body.body.first
    subject = Mutineer::Subject.new(file: "foo.rb", namespace: ["Foo"], name: :bar,
                                  singleton: false, def_node: def_node)
    start = src.index("log")
    finish = src.index(")", start) + 1 # end of `y)`
    mutation = Mutineer::Mutation.new(start_offset: start, end_offset: finish,
                                    replacement: "nil", operator: :statement_removal)
    result = Mutineer::Result.survived.with(subject: subject, mutation: mutation)

    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([result]), { "foo.rb" => src })
                    .report(out: out, err: StringIO.new)
    s = out.string

    assert_includes s, "Operator: statement_removal  (log(x, y) -> nil)" # token single-lined
    assert_includes s, "-     log(x,"   # first original line, indentation kept
    assert_includes s, "-         y)"   # second original line shown too
    assert_includes s, "+     nil"      # spliced replacement
    refute_match(/lonil|nilx|eminil/, s) # no fragment mashing
  end

  # #9: the human report distinguishes uncapturable (broken harness) from
  # no_coverage (genuine gap), in both the summary block and the score breakdown.
  def test_uncapturable_reported_separately_from_no_coverage
    out = StringIO.new
    reporter([Mutineer::Result.killed, survivor_result,
              Mutineer::Result.uncapturable, Mutineer::Result.no_coverage])
      .report(out: out, err: StringIO.new)
    s = out.string
    assert_includes s, "Uncapturable: 1"
    assert_includes s, "tests failed to run"
    assert_includes s, "No coverage:   1"
    assert_includes s, "1 uncapturable"      # listed as excluded in the score line
    assert_includes s, "Mutation score: 50.0%"
  end

  def test_na_score_warns_on_stderr
    out = StringIO.new
    err = StringIO.new
    reporter([Mutineer::Result.no_coverage]).report(out: out, err: err)
    assert_includes out.string, "Mutation score: N/A"
    assert_includes err.string, "threshold check is skipped"
  end

  # #11: a multi-source run shows a per-source line per file (sorted by path).
  def test_per_source_block_for_multiple_sources
    other = Mutineer::Subject.new(file: "other.rb", namespace: ["O"], name: :m,
                                  singleton: false, def_node: nil)
    out = StringIO.new
    Mutineer::Reporter.new(
      aggregate([survivor_result, Mutineer::Result.killed.with(subject: other)]),
      { FILE => SRC, "other.rb" => SRC }
    ).report(out: out, err: StringIO.new)
    s = out.string
    assert_includes s, "Per-source"
    assert_includes s, "other.rb  100.0%  (1 killed / 0 survived / 0 no-cov)"
    assert_includes s, "#{FILE}  0.0%  (0 killed / 1 survived / 0 no-cov)"
  end

  # A single-source run omits the redundant per-source block.
  def test_per_source_block_omitted_for_single_source
    out = StringIO.new
    reporter([survivor_result]).report(out: out, err: StringIO.new)
    refute_includes out.string, "Per-source"
  end

  def test_verdict_line_passed
    out = StringIO.new
    r = reporter([Mutineer::Result.killed, Mutineer::Result.killed,
                  Mutineer::Result.killed, Mutineer::Result.killed, survivor_result])
    r.report(out: out, err: StringIO.new, threshold: 80.0)
    assert_includes out.string, "PASSED: 80.0% >= threshold 80.0%"
  end

  def test_verdict_line_failed
    out = StringIO.new
    reporter([Mutineer::Result.killed, survivor_result])
      .report(out: out, err: StringIO.new, threshold: 80.0)
    assert_includes out.string, "FAILED: 50.0% < threshold 80.0%"
  end

  private

  def reporter(results)
    Mutineer::Reporter.new(aggregate(results), { FILE => SRC })
  end
end
