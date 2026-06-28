# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "tmpdir"

class JsonReporterTest < Minitest::Test
  SRC = "class Pricing\n  def total(price)\n    if price >= 100\n    end\n  end\nend\n"
  FILE = "pricing.rb"

  def mutation_at(token, replacement, operator)
    off = SRC.index(token)
    Mutineer::Mutation.new(start_offset: off, end_offset: off + token.length,
                         replacement: replacement, operator: operator)
  end

  def subject
    def_node = Mutineer::Parser.parse_string(SRC).value.statements.body.first.body.body.first
    Mutineer::Subject.new(file: FILE, namespace: ["Pricing"], name: :total,
                        singleton: false, def_node: def_node)
  end

  def survivor
    Mutineer::Result.survived.with(subject: subject, mutation: mutation_at(">=", ">", :comparison))
  end

  def render(results)
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new(results), { FILE => SRC })
                    .report(out: out, err: StringIO.new, format: "json")
    JSON.parse(out.string)
  end

  def test_valid_json_with_summary_and_score
    doc = render([Mutineer::Result.killed, survivor])
    assert_equal "1.0", doc["schema_version"]
    assert_equal 1, doc["summary"]["killed"]
    assert_equal 1, doc["summary"]["survived"]
    assert_equal 50.0, doc["summary"]["score"]
    assert doc["summary"].key?("timeout")
  end

  def test_survivor_entry_has_all_keys_and_diff
    s = render([survivor])["survivors"].first
    assert_equal "Pricing#total", s["subject"]
    assert_equal FILE, s["file"]
    assert_equal 3, s["line"]
    assert_equal "comparison", s["operator"]
    assert_includes s["diff"], "--- a/#{FILE}"
    assert_includes s["diff"], "+++ b/#{FILE}"
    assert_includes s["diff"], "@@ -3 +3 @@"
    assert_includes s["diff"], "-    if price >= 100"
    assert_includes s["diff"], "+    if price > 100"
  end

  def test_empty_arrays_when_nothing_survives
    doc = render([Mutineer::Result.killed])
    assert_equal [], doc["survivors"]
    assert_equal [], doc["no_coverage"]
    assert_equal 100.0, doc["summary"]["score"]
  end

  # C8: empty denominator emits null (not 0.0), matching the nil-vs-0.0 discipline.
  def test_zero_mutations_score_is_null_not_raise
    doc = render([])
    assert_nil doc["summary"]["score"]
    assert_equal 0, doc["summary"]["total"]
  end

  def test_all_errored_score_is_null_not_raise
    doc = render([Mutineer::Result.error, Mutineer::Result.timeout])
    assert_nil doc["summary"]["score"]
    assert_equal 2, doc["summary"]["total"]
    assert_operator doc["summary"]["errored"] + doc["summary"]["timeout"], :==, 2
  end

  def test_survivors_sorted_by_file_line_operator
    a = Mutineer::Result.survived.with(subject: subject, mutation: mutation_at("100", "0", :literal_mutation))
    b = Mutineer::Result.survived.with(subject: subject, mutation: mutation_at(">=", ">", :comparison))
    # input order [a (line 3, literal), b (line 3, comparison)]; comparison < literal
    ops = render([a, b])["survivors"].map { |s| s["operator"] }
    assert_equal %w[comparison literal_mutation], ops
  end

  def test_output_to_file_keeps_stdout_clean
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.json")
      out = StringIO.new
      err = StringIO.new
      Mutineer::Reporter.new(Mutineer::AggregateResult.new([survivor]), { FILE => SRC })
                      .report(out: out, err: err, format: "json", output: path)
      assert_empty out.string
      assert_includes err.string, "Report written to"
      assert JSON.parse(File.read(path))
    end
  end
end
