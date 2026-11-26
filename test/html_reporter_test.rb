# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"

class HtmlReporterTest < Minitest::Test
  SRC = "class Pricing\n  def total(price)\n    if price >= 100\n    end\n  end\nend\n"
  FILE = "pricing.rb"

  def mutation_at(token, replacement, operator)
    off = SRC.index(token)
    Mutineer::Mutation.new(start_offset: off, end_offset: off + token.length,
                           replacement: replacement, operator: operator)
  end

  def subject(file = FILE, namespace = ["Pricing"])
    def_node = Mutineer::Parser.parse_string(SRC).value.statements.body.first.body.body.first
    Mutineer::Subject.new(file: file, namespace: namespace, name: :total,
                          singleton: false, def_node: def_node)
  end

  def survivor
    Mutineer::Result.survived.with(subject: subject, mutation: mutation_at(">=", ">", :comparison),
                                   id: "pricing-total-comparison-1")
  end

  def render(results, source_map = { FILE => SRC }, unpaired: {})
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new(results), source_map, unpaired: unpaired)
                      .report(out: out, err: StringIO.new, format: "html")
    out.string
  end

  def test_self_contained_document_with_score_and_no_external_assets
    html = render([Mutineer::Result.killed, survivor])
    assert html.start_with?("<!DOCTYPE html"), "should start with the doctype"
    assert_includes html, "<style>"
    assert_includes html, "50.0%" # mutation score
    refute_match(%r{<link |<script |https?://}, html) # no external CSS/JS/CDN
  end

  def test_survivor_shows_subject_operator_id_and_diff
    s = survivor
    html = render([s])
    assert_includes html, "Pricing#total"
    assert_includes html, "comparison"
    assert_includes html, s.id # the stable id
    assert_includes html, "if price &gt; 100"  # mutated diff line, escaped
  end

  # #374: the HTML summary counts dropped repeats, and a survivor card lists their ids.
  def test_summary_and_survivor_name_dropped_copies
    row = survivor
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([row]), { FILE => SRC })
                      .report(out: out, err: StringIO.new, format: "html",
                              copies: { row.id => ["copy00000001"] })
    html = out.string
    assert_includes html, "<span><strong>1</strong> dropped</span>"
    assert_includes html, "copies <span class=\"id\">copy00000001</span>"
  end

  def test_summary_counts_unplaceable
    assert_includes render([Mutineer::Result.killed, Mutineer::Result.unplaceable]),
                    "<span><strong>1</strong> unplaceable</span>"
  end

  # #419: HTML shows the No mutants method count when the reporter has it.
  def test_summary_counts_no_mutants_and_declined
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([Mutineer::Result.killed]), { FILE => SRC })
                      .report(out: out, err: StringIO.new, format: "html",
                              subjects: 5, unmutated_subjects: [{ subject: "A#a", file: "a.rb", line: 1 }],
                              declined: { "range" => 2 })
    html = out.string
    assert_includes html, "<span><strong>1</strong> no_mutants</span>"
    assert_includes html, "<span><strong>5</strong> methods</span>"
    assert_includes html, "<span><strong>2</strong> declined</span>"
  end

  # #420: under --since, declined stays full-run and the HTML label says so.
  def test_scoped_declined_notes_not_narrowed
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([Mutineer::Result.killed]), { FILE => SRC })
                      .report(out: out, err: StringIO.new, format: "html", scoped: true,
                              declined: { "range" => 2 })
    assert_includes out.string, "<span><strong>2</strong> declined (not narrowed by --since)</span>"
  end

  def test_summary_counts_ran_at_load
    assert_includes render([Mutineer::Result.killed, Mutineer::Result.ran_at_load]),
                    "<span><strong>1</strong> ran_at_load</span>"
  end

  def test_summary_counts_unpaired_and_lists_the_sources
    html = render([Mutineer::Result.killed], unpaired: { "lib/b.rb" => 2, "lib/<a>.rb" => nil })
    assert_includes html, "<span><strong>2</strong> unpaired</span>"
    assert_includes html, "Sources with no paired test"
    assert_includes html, "lib/&lt;a&gt;.rb"
    assert_includes html, "unknown"
    assert_includes html, "lib/b.rb"
  end

  def test_unpaired_heading_is_absent_when_no_source_was_skipped
    html = render([Mutineer::Result.killed])
    assert_includes html, "<span><strong>0</strong> unpaired</span>"
    refute_includes html, "Sources with no paired test"
  end

  def test_source_is_html_escaped_not_raw
    html = render([survivor])
    assert_includes html, "if price &gt;= 100" # `>=` escaped in the original diff line
    refute_includes html, "if price >= 100"    # never the raw form
  end

  def test_multiple_sources_render_a_row_each
    other = subject("z.rb", ["Z"])
    results = [
      Mutineer::Result.killed.with(subject: subject),
      survivor,
      Mutineer::Result.killed.with(subject: other)
    ]
    html = render(results, { FILE => SRC, "z.rb" => SRC })
    assert_includes html, "Per-source"
    assert_includes html, ">#{FILE}<"
    assert_includes html, ">z.rb<"
  end

  def test_zero_mutation_case_renders_without_error
    html = render([])
    assert html.start_with?("<!DOCTYPE html")
    assert_includes html, "N/A" # nil score rendered, no raise
  end

  def test_output_to_file_keeps_stdout_clean
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.html")
      out = StringIO.new
      err = StringIO.new
      Mutineer::Reporter.new(Mutineer::AggregateResult.new([survivor]), { FILE => SRC })
                        .report(out: out, err: err, format: "html", output: path)
      assert_empty out.string
      assert_includes err.string, "Report written to"
      assert File.read(path).start_with?("<!DOCTYPE html")
    end
  end

  # --- kill matrix section (--matrix) ---------------------------------------

  def test_matrix_section_lists_blind_and_redundant_tests_escaped
    blind = ["test/pricing_test.rb", "PricingTest#test_<b>", "PricingTest#test_<b>"]
    killer = ["test/pricing_test.rb", "PricingTest#test_kill", "PricingTest#test_kill"]
    result = survivor.with(status: :killed,
                           kills: Mutineer::Kills.new(killed_by: [killer], ran: [blind, killer], complete: true))
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([result]), { FILE => SRC },
                           matrix: Mutineer::KillMatrix.new([result]))
                      .report(out: out, err: StringIO.new, format: "html")
    html = out.string

    assert_includes html, "<h2>Kill matrix</h2>"
    assert_includes html, "2 tests ran against 1 mutants"
    assert_includes html, "<h3>Blind tests (1)</h3>"
    assert_includes html, "PricingTest#test_&lt;b&gt;"
    refute_includes html, "test_<b>"
    assert_includes html, "<h3>Redundant tests (0)</h3>\n<p>None.</p>"
  end

  # #191 review: the HTML list is the full redundant list, so it carries the
  # delete warning too, and an incomplete matrix names every incomplete row.
  def test_matrix_section_warns_under_redundant_tests_and_names_incomplete_rows
    a = ["test/a_test.rb", "ATest#test_a", "ATest#test_a"]
    b = ["test/b_test.rb", "BTest#test_b", "BTest#test_b"]
    killed = survivor.with(status: :killed, kills: Mutineer::Kills.new(killed_by: [a, b], ran: [a, b], complete: true))
    stopped = survivor.with(status: :timeout, id: "abc123def456",
                            kills: Mutineer::Kills.new(killed_by: [], ran: [a], complete: false))
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([killed, stopped]), { FILE => SRC },
                           matrix: Mutineer::KillMatrix.new([killed, stopped]))
                      .report(out: out, err: StringIO.new, format: "html")
    html = out.string

    assert_includes html, "<p>Delete redundant tests one at a time: two of them can be the only killers of one mutant.</p>"
    assert_includes html, "Do not delete a blind test until these rows are complete:"
    assert_includes html, "<h3>Incomplete rows (1)</h3>\n<ul>\n<li>Pricing#total (#{FILE}:3) comparison timeout abc123def456</li>"
  end

  # PR #183 review: the HTML summary keeps timeouts apart from errored
  # mutants, as the human and JSON reports do.
  def test_summary_counts_timeouts_apart_from_errors
    html = render([Mutineer::Result.error("boom"), Mutineer::Result.timeout, Mutineer::Result.timeout])
    assert_includes html, "<span><strong>1</strong> errored</span>"
    assert_includes html, "<span><strong>2</strong> timeout</span>"
  end

  # #480: the HTML report lists each errored mutant and its cause; the
  # human report does so under --verbose only.
  def errored_mutant(details)
    Mutineer::Result.error(details).with(subject: subject, id: "abc123def456",
                                         mutation: mutation_at(">=", ">", :comparison))
  end

  def test_errored_section_lists_each_mutant_and_its_cause
    html = render([errored_mutant("LoadError: <x>"), Mutineer::Result.error(nil)])
    assert_includes html, "<h2>Errored mutants</h2>"
    assert_includes html, "#{FILE}:3 &middot; comparison &middot; <span class=\"id\">abc123def456</span>"
    assert_includes html, "<pre class=\"diff\">LoadError: &lt;x&gt;</pre>"
    assert_includes html, "no mutant location"
    assert_includes html, Mutineer::Reporter::ERRORED_NO_CAUSE
    refute_includes render([survivor]), "Errored mutants"
  end

  def test_human_errored_list_needs_verbose
    report = lambda do |verbose|
      out = StringIO.new
      Mutineer::Reporter.new(Mutineer::AggregateResult.new([errored_mutant("RuntimeError: boom")]), { FILE => SRC })
                        .report(out: out, err: StringIO.new, format: "human", verbose: verbose)
      out.string
    end
    assert_includes report.call(true),
                    "Errored Mutants\n---------------\n  Pricing#total (#{FILE}:3) comparison abc123def456\n" \
                    "    RuntimeError: boom\n"
    refute_includes report.call(false), "Errored Mutants"
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([Mutineer::Result.error("boom")]), { FILE => SRC })
                      .report(out: out, err: StringIO.new, format: "human", verbose: true)
    assert_includes out.string, "  unknown method (no mutant location)\n    boom\n"
    # An empty cause is no cause.
    assert_includes render([errored_mutant(" ")]), "<pre class=\"diff\">#{Mutineer::Reporter::ERRORED_NO_CAUSE}</pre>"
  end

  def test_no_matrix_section_without_the_flag
    refute_includes render([survivor]), "Kill matrix"
  end

  def test_ignored_section_shows_the_reason
    ignored = Mutineer::Result.ignored.with(subject: subject, id: "abc123def456",
                                            reason: "same value <raw>",
                                            mutation: mutation_at(">=", ">", :comparison))
    html = render([ignored])
    assert_includes html, "Ignored mutants"
    assert_includes html, "abc123def456"
    assert_includes html, "same value &lt;raw&gt;"
    refute_includes html, "same value <raw>"
  end


  # --- #343 limit 4: the HTML report shows the baseline comparison ---

  def baseline_delta(results, stored_ids, **opts)
    doc = { "schema_version" => "2.0", "summary" => { "score" => 100.0 },
            "survivors" => stored_ids.map { |id| { "id" => id, "subject" => "Pricing#total", "file" => FILE,
                                                    "line" => 3, "operator" => "comparison" } } }
    Mutineer::Baseline.new(doc).diff(Mutineer::AggregateResult.new(results), **opts)
  end

  def render_with(results, delta, format: "html", source_map: { FILE => SRC })
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new(results), source_map)
                      .report(out: out, err: StringIO.new, format: format, baseline: delta)
    out.string
  end

  def test_baseline_section_shows_a_regression_and_names_the_new_survivor
    results = [Mutineer::Result.killed, survivor]
    html = render_with(results, baseline_delta(results, []))
    assert_includes html, "<h2>Baseline comparison</h2>"
    assert_includes html, "REGRESSION vs baseline"
    assert_includes html, "  + Pricing#total (pricing.rb:3) comparison"
  end

  def test_baseline_section_shows_an_incomplete_run_and_the_unverified_survivors
    stored = Mutineer::Result.error.with(subject: subject, mutation: mutation_at(">=", ">", :comparison), id: "stored1")
    results = [stored, Mutineer::Result.error, Mutineer::Result.killed]
    html = render_with(results, baseline_delta(results, %w[stored1]))
    assert_includes html, "INCOMPLETE vs baseline"
    assert_includes html, "incomplete run: "
    assert_match(/  \? Pricing#total \(pricing\.rb:3\) comparison \[error\]/, html)
  end

  def test_baseline_section_holds_the_same_lines_as_the_human_report
    results = [Mutineer::Result.killed, survivor]
    delta = baseline_delta(results, %w[gone])
    html = render_with(results, delta)
    body = CGI.unescapeHTML(html[%r{<pre class="baseline">(.*?)</pre>}m, 1])
    human = render_with(results, delta, format: "human")
    section = human[/Baseline comparison\n-+\n(.*)\z/m, 1]
    assert_equal section, body
  end

  def test_baseline_section_is_html_escaped
    weird = Mutineer::Result.survived.with(subject: subject(FILE, ["A<b>&C"]),
                                           mutation: mutation_at(">=", ">", :comparison), id: "weird1")
    html = render_with([weird], baseline_delta([weird], []))
    section = html[%r{<pre class="baseline">(.*?)</pre>}m, 1]
    assert_includes section, "A&lt;b&gt;&amp;C"
    refute_includes section, "A<b>"
  end

  def test_no_baseline_section_without_a_baseline
    results = [Mutineer::Result.killed, survivor]
    assert_equal render(results), render_with(results, nil)
    refute_includes render(results), "Baseline comparison"
  end
end
