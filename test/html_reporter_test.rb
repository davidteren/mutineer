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

  def render(results, source_map = { FILE => SRC })
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new(results), source_map)
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

  def test_no_matrix_section_without_the_flag
    refute_includes render([survivor]), "Kill matrix"
  end

end
