# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class ReporterTest < Minitest::Test
  SRC = "class Pricing\n  def total(price)\n    if price >= 100\n    end\n  end\nend\n"
  FILE = "pricing.rb"

  def survivor_result
    def_node = Brutus::Parser.parse_string(SRC).value.statements.body.first.body.body.first
    subject = Brutus::Subject.new(file: FILE, namespace: ["Pricing"], name: :total,
                                  singleton: false, def_node: def_node)
    off = SRC.index(">=")
    mutation = Brutus::Mutation.new(start_offset: off, end_offset: off + 2,
                                    replacement: ">", operator: :comparison)
    Brutus::Result.survived.with(subject: subject, mutation: mutation)
  end

  def aggregate(results) = Brutus::AggregateResult.new(results)

  # --- AggregateResult contract ---

  def test_empty_score_is_nil
    agg = aggregate([])
    assert_nil agg.mutation_score
    assert_equal 0, agg.total
  end

  def test_score_excludes_no_coverage
    agg = aggregate([Brutus::Result.killed, Brutus::Result.survived,
                     Brutus::Result.no_coverage, Brutus::Result.no_coverage])
    assert_equal 50.0, agg.mutation_score
  end

  def test_score_excludes_errored_and_skipped
    agg = aggregate([Brutus::Result.killed, Brutus::Result.killed, Brutus::Result.killed,
                     Brutus::Result.survived, Brutus::Result.no_coverage,
                     Brutus::Result.no_coverage, Brutus::Result.error, Brutus::Result.skipped])
    assert_equal 75.0, agg.mutation_score
    assert_equal 8, agg.total
  end

  def test_all_no_coverage_score_nil
    assert_nil aggregate([Brutus::Result.no_coverage]).mutation_score
  end

  # --- exit_code ---

  def test_exit_code_threshold_off
    assert_equal 0, reporter([Brutus::Result.survived]).exit_code(threshold: 0)
  end

  def test_exit_code_below
    assert_equal 1, reporter([Brutus::Result.killed, Brutus::Result.survived]).exit_code(threshold: 80.0)
  end

  def test_exit_code_at_threshold_inclusive
    r = reporter([Brutus::Result.killed, Brutus::Result.killed,
                  Brutus::Result.killed, Brutus::Result.killed, Brutus::Result.survived])
    assert_equal 0, r.exit_code(threshold: 80.0) # 80.0 >= 80.0
  end

  def test_exit_code_nil_score_skips_gate
    assert_equal 0, reporter([Brutus::Result.no_coverage]).exit_code(threshold: 80.0)
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
    def_node = Brutus::Parser.parse_string(src).value.statements.body.first.body.body.first
    subject = Brutus::Subject.new(file: "foo.rb", namespace: ["Foo"], name: :bar,
                                  singleton: false, def_node: def_node)
    start = src.index("log")
    finish = src.index(")", start) + 1 # end of `y)`
    mutation = Brutus::Mutation.new(start_offset: start, end_offset: finish,
                                    replacement: "nil", operator: :statement_removal)
    result = Brutus::Result.survived.with(subject: subject, mutation: mutation)

    out = StringIO.new
    Brutus::Reporter.new(Brutus::AggregateResult.new([result]), { "foo.rb" => src })
                    .report(out: out, err: StringIO.new)
    s = out.string

    assert_includes s, "Operator: statement_removal  (log(x, y) -> nil)" # token single-lined
    assert_includes s, "-     log(x,"   # first original line, indentation kept
    assert_includes s, "-         y)"   # second original line shown too
    assert_includes s, "+     nil"      # spliced replacement
    refute_match(/lonil|nilx|eminil/, s) # no fragment mashing
  end

  def test_na_score_warns_on_stderr
    out = StringIO.new
    err = StringIO.new
    reporter([Brutus::Result.no_coverage]).report(out: out, err: err)
    assert_includes out.string, "Mutation score: N/A"
    assert_includes err.string, "threshold check is skipped"
  end

  def test_verdict_line_passed
    out = StringIO.new
    r = reporter([Brutus::Result.killed, Brutus::Result.killed,
                  Brutus::Result.killed, Brutus::Result.killed, survivor_result])
    r.report(out: out, err: StringIO.new, threshold: 80.0)
    assert_includes out.string, "PASSED: 80.0% >= threshold 80.0%"
  end

  def test_verdict_line_failed
    out = StringIO.new
    reporter([Brutus::Result.killed, survivor_result])
      .report(out: out, err: StringIO.new, threshold: 80.0)
    assert_includes out.string, "FAILED: 50.0% < threshold 80.0%"
  end

  private

  def reporter(results)
    Brutus::Reporter.new(aggregate(results), { FILE => SRC })
  end
end
