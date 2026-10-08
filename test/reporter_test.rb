# frozen_string_literal: true

require_relative "test_helper"
require "json"
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

  # A score over a slice of the run is not this suite's score: 90 errored and 10
  # run (9 killed) reads 90% and used to exit 0, so CI could not tell a complete
  # run from a broken one.
  def test_exit_code_fails_when_most_attempted_mutants_produced_no_verdict
    results = Array.new(90) { Mutineer::Result.error("daemon worker crashed") } +
              Array.new(9) { Mutineer::Result.killed } + [Mutineer::Result.survived]
    r = reporter(results)

    assert_equal 90.0, r.instance_variable_get(:@agg).mutation_score
    assert_equal 1, r.exit_code(threshold: 80.0)
  end

  # The report's verdict line and the exit code must come from one rule, or a run
  # that exits 1 prints PASSED — and with --output that is what gets archived.
  def test_verdict_line_agrees_with_the_exit_code
    results = Array.new(90) { Mutineer::Result.error("crash") } +
              Array.new(9) { Mutineer::Result.killed } + [survivor_result]
    out = StringIO.new
    r = reporter(results)
    r.human_report(out, StringIO.new, 80.0)

    assert_equal 1, r.exit_code(threshold: 80.0)
    refute_match(/PASSED/, out.string, "the report said PASSED on a run that exits 1")
    assert_match(/FAILED: 90 of 100 attempted/, out.string)
  end

  # --format json is the documented CI path, so the reason must not live only in
  # the renderer a person reads.
  def test_the_gate_explains_itself_on_every_format
    results = Array.new(90) { Mutineer::Result.error("crash") } +
              Array.new(9) { Mutineer::Result.killed } + [survivor_result]

    %w[json human].each do |format|
      err = StringIO.new
      reporter(results).report(out: StringIO.new, err: err, threshold: 80.0, format: format)

      assert_match(/90 of 100 attempted mutants produced no verdict/, err.string, "#{format}: no reason given")
      assert_match(/limit 10%/, err.string, "#{format}: never states the rule")
    end
  end

  # A --since PR run can yield a handful of mutants, where one timeout is over 10%.
  # One bad mutant must never fail the gate on its own, at any run size.
  def test_a_single_broken_mutant_never_fails_the_gate
    assert_equal 0, reporter([Mutineer::Result.timeout] + Array.new(4) { Mutineer::Result.killed })
      .exit_code(threshold: 80.0)
  end

  # The flip side: a couple of flaky mutants in a large run must not turn CI red.
  def test_exit_code_tolerates_a_few_broken_mutants
    results = Array.new(3) { Mutineer::Result.error("flake") } +
              Array.new(900) { Mutineer::Result.killed } +
              Array.new(97) { Mutineer::Result.survived }

    assert_equal 0, reporter(results).exit_code(threshold: 80.0)
  end

  # Timeouts and uncapturable count toward the same limit — all three mean the
  # mutant was attempted and no verdict came back.
  def test_exit_code_counts_timeouts_and_uncapturable_as_broken
    results = Array.new(5) { Mutineer::Result.timeout } +
              Array.new(5) { Mutineer::Result.uncapturable } +
              Array.new(10) { Mutineer::Result.killed }

    assert_equal 1, reporter(results).exit_code(threshold: 50.0)
  end

  def test_exit_code_does_not_count_unplaceable_toward_the_no_verdict_limit
    results = Array.new(5) { Mutineer::Result.unplaceable } +
              Array.new(9) { Mutineer::Result.killed } + [Mutineer::Result.survived]

    assert_equal 0, reporter(results).exit_code(threshold: 80.0)
  end

  # #187: ran_at_load is not a broken harness, so it never fails --threshold.
  def test_exit_code_does_not_count_ran_at_load_toward_the_no_verdict_limit
    results = Array.new(5) { Mutineer::Result.ran_at_load } +
              Array.new(9) { Mutineer::Result.killed } + [Mutineer::Result.survived]

    assert_equal 0, reporter(results).exit_code(threshold: 80.0)
    assert_equal 0, reporter([Mutineer::Result.ran_at_load]).exit_code(threshold: 80.0)
  end

  def test_exit_code_nil_score_all_unplaceable_skips_gate
    assert_equal 0, reporter([Mutineer::Result.unplaceable]).exit_code(threshold: 80.0)
  end

  def test_exit_code_nil_score_pure_no_coverage_skips_gate
    assert_equal 0, reporter([Mutineer::Result.no_coverage]).exit_code(threshold: 80.0)
  end

  def test_exit_code_nil_score_all_ignored_skips_gate
    assert_equal 0, reporter([Mutineer::Result.ignored]).exit_code(threshold: 80.0)
  end

  def test_exit_code_nil_score_with_errors_fails_gate
    assert_equal 1, reporter([Mutineer::Result.error("boom")]).exit_code(threshold: 80.0)
  end

  def test_exit_code_nil_score_with_timeouts_fails_gate
    assert_equal 1, reporter([Mutineer::Result.timeout]).exit_code(threshold: 80.0)
  end

  def test_exit_code_nil_score_with_uncapturable_fails_gate
    assert_equal 1, reporter([Mutineer::Result.uncapturable]).exit_code(threshold: 80.0)
  end

  # --- rendering / streams ---

  # Errors are out of the score, so a run without --threshold exits 0 however
  # many mutants errored. Say so, and name the flag that fails CI on them.
  def test_errors_without_a_threshold_point_at_the_threshold_flag
    results = [Mutineer::Result.error("boom"), Mutineer::Result.error("boom"), Mutineer::Result.killed]
    err = StringIO.new
    reporter(results).report(out: StringIO.new, err: err)
    assert_includes err.string, "2 mutants errored. Errors are not in the score, so they do not fail a run without a positive --threshold."
    assert_includes err.string, "more than one mutant has no verdict and they exceed 10% of those attempted"

    err = StringIO.new
    reporter([Mutineer::Result.error("boom"), Mutineer::Result.killed]).report(out: StringIO.new, err: err)
    assert_includes err.string, "1 mutant errored."

    err = StringIO.new
    reporter(results).report(out: StringIO.new, err: err, threshold: 50.0)
    refute_includes err.string, "Errors are not in the score"

    err = StringIO.new
    reporter([Mutineer::Result.killed]).report(out: StringIO.new, err: err)
    refute_includes err.string, "errored"
  end

  # The CLI explains an empty run (see CLI.warn_empty_run), once, for every
  # format; the human report adds nothing of its own.
  def test_zero_mutations_report_is_empty
    out = StringIO.new
    err = StringIO.new
    reporter([]).report(out: out, err: err)
    assert_empty out.string
    assert_empty err.string
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

  # #163: a control byte in a surviving line prints as an escape, not raw, in
  # the human report. A tab stays. JSON keeps the raw character.
  def test_human_survivor_escapes_control_characters
    src = "class Foo\n  def bar(x)\n    \"\e[2J\x7F\r\u009B\" if x >= 1\t# t\n  end\nend\n"
    def_node = Mutineer::Parser.parse_string(src).value.statements.body.first.body.body.first
    subject = Mutineer::Subject.new(file: "foo.rb", namespace: ["Foo"], name: :bar,
                                    singleton: false, def_node: def_node)
    at = src.byteindex(">=")
    mutation = Mutineer::Mutation.new(start_offset: at, end_offset: at + 2, replacement: ">", operator: :comparison)
    agg = Mutineer::AggregateResult.new([Mutineer::Result.survived.with(subject: subject, mutation: mutation)])

    out = StringIO.new
    Mutineer::Reporter.new(agg, { "foo.rb" => src }).report(out: out, err: StringIO.new)
    refute_includes out.string, "\e"
    assert_includes out.string, %(-     "\\e[2J\\x7F\\r\\u009B" if x >= 1\t# t)
    assert_includes out.string, %(+     "\\e[2J\\x7F\\r\\u009B" if x > 1\t# t)

    # A source read under LANG=C is tagged US-ASCII; UTF-8 after the token
    # still prints as UTF-8, not as `??`.
    ascii_src = "class Foo\n  def bar(x)\n    x >= 1 # caf\u00e9\n  end\nend\n".dup.force_encoding(Encoding::US_ASCII)
    ascii_at = ascii_src.byteindex(">=")
    ascii_mutation = Mutineer::Mutation.new(start_offset: ascii_at, end_offset: ascii_at + 2, replacement: ">",
                                            operator: :comparison)
    ascii_agg = Mutineer::AggregateResult.new([Mutineer::Result.survived.with(subject: subject, mutation: ascii_mutation)])
    out = StringIO.new
    Mutineer::Reporter.new(ascii_agg, { "foo.rb" => ascii_src }).report(out: out, err: StringIO.new)
    assert_includes out.string, "+     x > 1 # caf\u00e9"

    # A file name and a method name with a control character are escaped too.
    named = Mutineer::Subject.new(file: "f\eoo.rb", namespace: ["Foo"], name: :"b\u009Bar",
                                  singleton: false, def_node: def_node)
    named_agg = Mutineer::AggregateResult.new([Mutineer::Result.survived.with(subject: named, mutation: mutation)])
    out = StringIO.new
    Mutineer::Reporter.new(named_agg, { "f\eoo.rb" => src }).report(out: out, err: StringIO.new)
    refute_includes out.string, "\e"
    assert_includes out.string, "f\\eoo.rb"
    assert_includes out.string, "Foo#b\\u009Bar"

    json = StringIO.new
    Mutineer::Reporter.new(agg, { "foo.rb" => src }).report(out: json, err: StringIO.new, format: "json")
    assert_includes JSON.parse(json.string)["survivors"].first["diff"], "\e[2J"
  end

  # #163: the token and replacement on the Operator line are escaped too, and
  # an invalid UTF-8 byte after the token does not crash the report.
  def test_human_operator_line_escapes_and_survives_invalid_utf8
    src = "class Foo\n  def bar\n    \"\e[2J\" # caf\xE9\n  end\nend\n".b.force_encoding(Encoding::UTF_8)
    def_node = Mutineer::Parser.parse_string(src).value.statements.body.first.body.body.first
    subject = Mutineer::Subject.new(file: "foo.rb", namespace: ["Foo"], name: :bar,
                                    singleton: false, def_node: def_node)
    at = src.byteindex("\"")
    mutation = Mutineer::Mutation.new(start_offset: at, end_offset: at + 6, replacement: "\"\e\"",
                                      operator: :string_literal)
    agg = Mutineer::AggregateResult.new([Mutineer::Result.survived.with(subject: subject, mutation: mutation)])

    out = StringIO.new
    Mutineer::Reporter.new(agg, { "foo.rb" => src }).report(out: out, err: StringIO.new)
    refute_includes out.string.b, "\e".b
    assert_includes out.string, %(string_literal  ("\\e[2J" -> "\\e"))
    # PR #196 review: a byte that is not UTF-8 (Latin-1 é) shows as an escape, not as U+FFFD.
    assert_includes out.string, "# caf\\xE9"
    refute_includes out.string, "\uFFFD"
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

  def test_unplaceable_reported_on_its_own_line_apart_from_uncapturable
    out = StringIO.new
    reporter([Mutineer::Result.killed, survivor_result, Mutineer::Result.unplaceable])
      .report(out: out, err: StringIO.new)
    s = out.string
    assert_includes s, "Unplaceable:  1"
    assert_includes s, "Uncapturable: 0"
    assert_includes s, "1 unplaceable"
    assert_includes s, "Mutation score: 50.0%"
  end

  def test_ran_at_load_reported_on_its_own_line_pointing_at_test_command
    out = StringIO.new
    reporter([Mutineer::Result.killed, survivor_result, Mutineer::Result.ran_at_load])
      .report(out: out, err: StringIO.new)
    s = out.string
    assert_match(/^Ran at load:  1 .*--test-command/, s)
    assert_includes s, "1 ran at load"
    assert_includes s, "Mutation score: 50.0%"
  end

  def test_na_score_warns_on_stderr
    out = StringIO.new
    err = StringIO.new
    reporter([Mutineer::Result.no_coverage]).report(out: out, err: err)
    assert_includes out.string, "Mutation score: N/A"
    assert_includes err.string, "threshold check is skipped"
  end

  def test_na_score_broken_harness_fails_gate_with_clear_message
    out = StringIO.new
    err = StringIO.new
    reporter([Mutineer::Result.error("boom"), Mutineer::Result.timeout])
      .report(out: out, err: err, threshold: 80.0)
    assert_includes out.string, "Errored:       1"
    assert_includes out.string, "Timeout:      1"
    assert_includes out.string, "1 errored, 1 timeout"
    assert_includes out.string, "Mutation score: N/A"
    assert_includes err.string, "threshold gate fails"
    assert_includes out.string, "FAILED: no covered mutants"
    refute_includes err.string, "threshold check is skipped"
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

  def test_matrix_section_names_blind_and_redundant_tests
    a = ["test/a_test.rb", "ATest#test_a", "ATest#test_a"]
    b = ["test/b_test.rb", "BTest#test_b", "BTest#test_b"]
    c = ["test/c_test.rb", "CTest#test_c", "CTest#test_c"]
    text = matrix_report([row(survivor_result.with(status: :killed), [a, b], [c])])

    assert_includes text, "Kill matrix\n-----------\n3 tests ran against 1 mutants"
    assert_includes text, "Blind tests (ran, killed no mutant): 1\n  test/c_test.rb  CTest#test_c\n"
    assert_includes text, "Redundant tests (each mutant they kill has another killer): 2\n" \
                          "  test/a_test.rb  ATest#test_a\n  test/b_test.rb  BTest#test_b\n"
    assert_includes text, "Delete redundant tests one at a time"
    refute_includes text, "could not be verified as complete"
  end

  # #191 review: the warning names every cause, says not to delete a blind
  # test yet, names the incomplete rows (at most 20) and points at the full lists.
  def test_incomplete_matrix_names_the_rows_and_says_a_blind_test_may_be_wrong
    text = matrix_report([row(survivor_result.with(status: :timeout, id: "abc123def456"), [],
                              [["t.rb", "T#test", "T#test"]], complete: false)])
    assert_includes text, "1 mutants could not be verified as complete (a timeout, an error, an exit, " \
                          "an interrupt or a broken stream), so a blind test may have killed one of them. " \
                          "Do not delete a blind test until these rows are complete:\n" \
                          "  Pricing#total (#{FILE}:3) comparison timeout abc123def456\n" \
                          "The HTML and JSON reports list every incomplete row"
  end

  def test_incomplete_matrix_names_at_most_twenty_rows
    rows = (1..25).map do |i|
      row(survivor_result.with(status: :timeout, id: format("id%02d", i)), [], [["t.rb", "T#test", "T#test"]],
          complete: false)
    end
    text = matrix_report(rows)
    assert_includes text, "comparison timeout id20\n  and 5 more\n"
    refute_includes text, "id21"
  end

  # PR #196 review: test names and paths in the kill-matrix section are user
  # text too (an RSpec description), so they are escaped like the rest.
  def test_matrix_section_escapes_control_characters
    blind = ["spec/s\e_spec.rb", "S clears \e[2J", "./spec/s_spec.rb[1:1]"]
    text = matrix_report([row(survivor_result, [], [blind])])
    refute_includes text, "\e"
    assert_includes text, "spec/s\\e_spec.rb  S clears \\e[2J"
  end

  # An RSpec id differs from the description and tells apart examples that
  # share one, so the human report shows it.
  def test_matrix_section_shows_an_id_that_differs_from_the_name
    blind = ["spec/s_spec.rb", "S checks", "./spec/s_spec.rb[1:1]"]
    text = matrix_report([row(survivor_result, [], [blind])])
    assert_includes text, "  spec/s_spec.rb  S checks (./spec/s_spec.rb[1:1])\n"
  end

  def test_matrix_section_lists_at_most_twenty_tests_each
    tests = (1..25).map { |i| ["t_test.rb", format("T#test_%02d", i), format("T#test_%02d", i)] }
    text = matrix_report([row(survivor_result, [], tests)])
    assert_includes text, "Blind tests (ran, killed no mutant): 25\n"
    assert_includes text, "  t_test.rb  T#test_20\n  and 5 more; see --format json\n"
    refute_includes text, "T#test_21"
  end

  def test_no_matrix_section_without_the_flag
    out = StringIO.new
    Mutineer::Reporter.new(aggregate([survivor_result]), { FILE => SRC }).report(out: out, err: StringIO.new)
    refute_includes out.string, "Kill matrix"
  end

  private

  def matrix_report(results)
    out = StringIO.new
    Mutineer::Reporter.new(aggregate(results), { FILE => SRC }, matrix: Mutineer::KillMatrix.new(results))
                      .report(out: out, err: StringIO.new)
    out.string
  end

  def row(result, killed_by, ran, complete: true)
    result.with(kills: Mutineer::Kills.new(killed_by: killed_by, ran: (ran + killed_by).uniq.sort, complete: complete))
  end

  def reporter(results)
    Mutineer::Reporter.new(aggregate(results), { FILE => SRC })
  end

end
