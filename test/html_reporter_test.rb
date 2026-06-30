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
end
