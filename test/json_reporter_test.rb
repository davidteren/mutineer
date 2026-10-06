# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "tmpdir"
require "open3"

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

  def test_schema_version_is_the_reporter_constant
    assert_equal Mutineer::Reporter::SCHEMA_VERSION, render([survivor])["schema_version"]
  end

  # Renders one survivor's JSON diff and checks that git applies it to `src`
  # and gives the same file as Mutation#apply.
  def assert_git_applies(subj, src, mutation, header)
    result = Mutineer::Result.survived.with(subject: subj, mutation: mutation)
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([result]), { "foo.rb" => src })
                      .report(out: out, err: StringIO.new, format: "json")
    diff = JSON.parse(out.string)["survivors"].first["diff"]
    assert_includes diff, header

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "foo.rb"), src)
      File.write(File.join(dir, "m.patch"), diff)
      _, err, status = Open3.capture3("git", "apply", "--unidiff-zero", "m.patch", chdir: dir)
      assert status.success?, "git apply rejected #{header}: #{err}\n#{diff}"
      assert_equal mutation.apply(src), File.read(File.join(dir, "foo.rb"))
    end
  end

  def test_valid_json_with_summary_and_score
    doc = render([Mutineer::Result.killed, survivor])
    assert_equal "1.7", doc["schema_version"] # 1.6 added operator, token and id to no_coverage[] and uncapturable[]; 1.5 the --matrix block
    assert_equal 1, doc["summary"]["killed"]
    assert_equal 1, doc["summary"]["survived"]
    assert_equal 50.0, doc["summary"]["score"]
    assert doc["summary"].key?("timeout")
    assert_equal false, doc["summary"]["scoped"], "unscoped run records scoped: false"
  end

  # #126: the report names its id format, so a later --baseline load knows its
  # ids include the file path. With no legacy data the two counts are zero.
  def test_summary_records_the_id_format_and_zero_legacy_matches
    doc = render([Mutineer::Result.killed, survivor])
    assert_equal 2, doc["summary"]["id_format"]
    assert_equal({ "ignore" => 0, "baseline" => 0 }, doc["summary"]["legacy_id_matches"])
  end

  # Each count needs a different fix (edit the ignore list vs regenerate the
  # baseline), so the report keeps them apart.
  def test_summary_carries_separate_legacy_id_match_counts
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([Mutineer::Result.killed]), { FILE => SRC })
                      .report(out: out, err: StringIO.new, format: "json",
                              legacy_id_matches: { ignore: 2, baseline: 1 })
    doc = JSON.parse(out.string)
    assert_equal({ "ignore" => 2, "baseline" => 1 }, doc["summary"]["legacy_id_matches"])
  end

  # A --since run's report must say so, so a consumer (or a later --baseline
  # load) knows its score covers only the changed-line mutants.
  def test_scoped_run_records_scoped_true
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new([Mutineer::Result.killed]), { FILE => SRC })
                      .report(out: out, err: StringIO.new, format: "json", scoped: true)
    assert_equal true, JSON.parse(out.string)["summary"]["scoped"]
  end

  # Until this key existed, Result#details was built and rendered nowhere, so a
  # daemon crash reached the user as nothing but a bump in the errored count.
  def test_no_verdict_entries_carry_their_cause
    doc = render([Mutineer::Result.error("daemon worker crashed: Errno::EPIPE"),
                  Mutineer::Result.timeout, Mutineer::Result.killed])
    entries = doc["no_verdict"]

    assert_equal 2, entries.size
    assert_equal doc["summary"]["no_verdict"], entries.size
    crash = entries.find { |e| e["status"] == "error" }
    assert_match(/daemon worker crashed/, crash["details"])
    assert_equal "timeout", entries.find { |e| e["status"] == "timeout" }["status"]
  end

  # A pre-fork failure has no subject or mutation, so its file and line are null.
  # It must still appear rather than break the sort or vanish from the array.
  def test_no_verdict_entry_without_a_subject_still_appears
    doc = render([Mutineer::Result.error("boot failed"), survivor])
    entry = doc["no_verdict"].first

    assert_nil entry["file"]
    assert_nil entry["line"]
    assert_equal "boot failed", entry["details"]
  end

  # The gate counts uncapturable, and the docs send the user to no_verdict[] to see
  # what failed, so a run failed purely by uncapturable mutants must not find it empty.
  def test_no_verdict_includes_uncapturable_because_the_gate_counts_it
    unc = Mutineer::Result.uncapturable.with(subject: subject,
                                             mutation: mutation_at("100", "0", :literal_mutation))
    doc = render([unc, Mutineer::Result.killed])

    assert_equal 1, doc["no_verdict"].size
    assert_equal "uncapturable", doc["no_verdict"].first["status"]
    assert_equal doc["summary"]["no_verdict"], doc["no_verdict"].size
    # It keeps its own lean array too, for consumers that already read that key.
    assert_equal 1, doc["uncapturable"].size
  end

  # Entries collide on (file, line) far more than survivors do — every pre-fork
  # entry lands on the same key — and sort_by is not stable, so without id and
  # status in the key the array would carry worker finish order between runs.
  def test_no_verdict_order_is_stable_for_colliding_entries
    a = Mutineer::Result.error("one").with(subject: subject, mutation: mutation_at(">=", ">", :comparison), id: "aaa")
    b = Mutineer::Result.error("two").with(subject: subject, mutation: mutation_at(">=", ">", :comparison), id: "bbb")
    pre1 = Mutineer::Result.error("boot a")
    pre2 = Mutineer::Result.timeout

    forward = render([a, b, pre1, pre2])["no_verdict"]
    reverse = render([pre2, pre1, b, a])["no_verdict"]

    assert_equal forward, reverse, "the array must not carry input order between runs"
  end

  # The two figures the completeness gate is computed from, so a consumer never has
  # to re-derive which statuses count.
  def test_summary_carries_the_figures_the_gate_uses
    uncovered = Mutineer::Result.no_coverage.with(subject: subject,
                                                  mutation: mutation_at("100", "0", :literal_mutation))
    doc = render([Mutineer::Result.error("x"), Mutineer::Result.killed, uncovered])

    assert_equal 2, doc["summary"]["attempted"] # no_coverage was never attempted
    assert_equal 1, doc["summary"]["no_verdict"]
  end

  def test_no_coverage_entry_names_the_mutation_and_carries_its_id
    uncovered = Mutineer::Result.no_coverage.with(subject: subject, id: "abc123def456",
                                                  mutation: mutation_at("100", "0", :literal_mutation))
    entry = render([uncovered])["no_coverage"].first

    expected = { "subject" => "Pricing#total", "file" => FILE, "line" => 3,
                 "operator" => "literal_mutation", "token" => "100", "id" => "abc123def456" }
    assert_equal expected, entry
  end

  def test_ignored_entries_on_one_line_and_operator_are_ordered_by_id
    later = Mutineer::Result.ignored.with(subject: subject, id: "bbbbbbbbbbbb",
                                          mutation: mutation_at(">=", ">", :comparison))
    earlier = Mutineer::Result.ignored.with(subject: subject, id: "aaaaaaaaaaaa",
                                            mutation: mutation_at(">=", "<", :comparison))

    assert_equal %w[aaaaaaaaaaaa bbbbbbbbbbbb], render([later, earlier])["ignored"].map { |e| e["id"] }
  end

  def test_no_coverage_entries_on_one_line_are_ordered_by_operator_then_id
    first = Mutineer::Result.no_coverage.with(subject: subject, id: "bbbbbbbbbbbb",
                                              mutation: mutation_at(">=", ">", :comparison))
    second = Mutineer::Result.no_coverage.with(subject: subject, id: "aaaaaaaaaaaa",
                                               mutation: mutation_at("100", "0", :literal_mutation))
    third = Mutineer::Result.no_coverage.with(subject: subject, id: "aaaaaaaaaaaa",
                                              mutation: mutation_at(">=", "<", :comparison))

    ids = render([second, first, third])["no_coverage"].map { |e| [e["operator"], e["id"]] }
    assert_equal [%w[comparison aaaaaaaaaaaa], %w[comparison bbbbbbbbbbbb], %w[literal_mutation aaaaaaaaaaaa]], ids
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

  # #106: a mutant on the last line of a file with no final newline marks both
  # sides, so git apply does not add a newline.
  def test_survivor_diff_at_end_of_file_without_newline_applies_with_git
    src = "class Foo\n  def bar(x) = x >= 1\nend"
    def_node = Mutineer::Parser.parse_string(src).value.statements.body.first.body.body.first
    subj = Mutineer::Subject.new(file: "foo.rb", namespace: ["Foo"], name: :bar,
                                 singleton: false, def_node: def_node)
    tail = Mutineer::Mutation.new(start_offset: src.index("x >= 1"), end_offset: src.bytesize,
                                  replacement: "x > 1\nend", operator: :comparison)
    assert_git_applies(subj, src, tail, "@@ -2,2 +2,2 @@")
    # A one-line mutant on a last line with no final newline.
    one_line_src = "class Foo; def bar(x) = x >= 1; end"
    one_line = Mutineer::Mutation.new(start_offset: one_line_src.index(">="), end_offset: one_line_src.index(">=") + 2,
                                      replacement: ">", operator: :comparison)
    assert_git_applies(subj, one_line_src, one_line, "@@ -1 +1 @@\n-class Foo; def bar(x) = x >= 1; end\n\\ No newline")
  end

  # PR #194 review: the newline state is each side's own. A replacement that
  # adds the missing final newline, and a range that ends right after the
  # file's final newline, both apply.
  def test_survivor_diff_tracks_each_sides_final_newline
    src = "class Foo; def bar(x) = x >= 1; end"
    def_node = Mutineer::Parser.parse_string(src).value.statements.body.first.body.body.first
    subj = Mutineer::Subject.new(file: "foo.rb", namespace: ["Foo"], name: :bar,
                                 singleton: false, def_node: def_node)
    adds_newline = Mutineer::Mutation.new(start_offset: src.index("end"), end_offset: src.bytesize,
                                          replacement: "end\n", operator: :statement_removal)
    assert_git_applies(subj, src, adds_newline, "@@ -1 +1 @@\n-#{src}\n\\ No newline at end of file\n+#{src}\n")

    with_newline = "#{src}\n"
    covers_final_newline = Mutineer::Mutation.new(start_offset: with_newline.index(">="),
                                                  end_offset: with_newline.bytesize,
                                                  replacement: "> 1; end\n", operator: :comparison)
    assert_git_applies(subj, with_newline, covers_final_newline, "@@ -1 +1 @@")
  end

  # #106: a CRLF file keeps its "\r" in the diff, so git applies it unchanged.
  def test_survivor_diff_of_a_crlf_file_applies_with_git
    src = "class Foo\r\n  def bar(x)\r\n    log(x,\r\n        y)\r\n    x\r\n  end\r\nend\r\n"
    def_node = Mutineer::Parser.parse_string(src).value.statements.body.first.body.body.first
    subj = Mutineer::Subject.new(file: "foo.rb", namespace: ["Foo"], name: :bar,
                                 singleton: false, def_node: def_node)
    multiline = Mutineer::Mutation.new(start_offset: src.index("log"), end_offset: src.index("y)") + 2,
                                       replacement: "nil", operator: :statement_removal)
    assert_git_applies(subj, src, multiline, "@@ -3,2 +3 @@")
  end

  # #106: the hunk header counts the lines the diff removes and adds, so an
  # independent consumer (git apply) accepts the patch, and applying it gives
  # the same file as Mutation#apply.
  def test_survivor_diffs_apply_cleanly_with_git
    src = "class Foo\n  def bar(x)\n    log(x,\n        y)\n    \"caf\u00e9\" if x >= 1\n    x\n  end\nend\n"
    def_node = Mutineer::Parser.parse_string(src).value.statements.body.first.body.body.first
    subj = Mutineer::Subject.new(file: "foo.rb", namespace: ["Foo"], name: :bar,
                                 singleton: false, def_node: def_node)
    multiline = Mutineer::Mutation.new(start_offset: src.index("log"), end_offset: src.index("y)") + 2,
                                       replacement: "nil", operator: :statement_removal)
    utf8 = Mutineer::Mutation.new(start_offset: src.byteindex(">="), end_offset: src.byteindex(">=") + 2,
                                  replacement: ">", operator: :comparison)
    # Empties a line: the `+` side is one empty line, not zero lines.
    line_start = src.byteindex("    x\n  end")
    emptied = Mutineer::Mutation.new(start_offset: line_start, end_offset: line_start + 5,
                                     replacement: "", operator: :statement_removal)
    # A replacement ending in a newline adds a line.
    split = Mutineer::Mutation.new(start_offset: line_start + 4, end_offset: line_start + 5,
                                   replacement: "x\n", operator: :statement_removal)

    { multiline => "@@ -3,2 +3 @@", utf8 => "@@ -5 +5 @@", emptied => "@@ -6 +6 @@\n-    x\n+\n",
      split => "@@ -6 +6,2 @@" }.each { |m, header| assert_git_applies(subj, src, m, header) }
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

  # #9: additive uncapturable count + list, distinct from no_coverage; score unaffected.
  def test_uncapturable_summary_count_and_list
    unc = Mutineer::Result.uncapturable.with(subject: subject, id: "abc123def456",
                                             mutation: mutation_at("100", "0", :literal_mutation))
    doc = render([Mutineer::Result.killed, survivor, unc])
    assert_equal 1, doc["summary"]["uncapturable"]
    assert_equal 50.0, doc["summary"]["score"] # killed+survived only; uncapturable excluded
    entry = doc["uncapturable"].first
    assert_equal "Pricing#total", entry["subject"]
    assert_equal FILE, entry["file"]
    assert_equal 3, entry["line"]
    assert_equal %w[literal_mutation 100 abc123def456], entry.values_at("operator", "token", "id")
    assert_equal [], doc["no_coverage"] # not conflated with no_coverage
  end

  def test_unplaceable_summary_count_and_list_stay_out_of_no_verdict
    unp = Mutineer::Result.unplaceable.with(subject: subject, id: "abc123def456",
                                            mutation: mutation_at("100", "0", :literal_mutation))
    doc = render([Mutineer::Result.killed, survivor, unp])
    assert_equal 1, doc["summary"]["unplaceable"]
    assert_equal [0, 0, 2, 50.0], doc["summary"].values_at("uncapturable", "no_verdict", "attempted", "score")
    entry = doc["unplaceable"].first
    assert_equal ["Pricing#total", FILE, 3], entry.values_at("subject", "file", "line")
    assert_equal %w[literal_mutation 100 abc123def456], entry.values_at("operator", "token", "id")
    assert_equal [], doc["uncapturable"]
    assert_equal [], doc["no_verdict"]
  end

  # #11: additive per_source array, sorted by file, with per-file counts + score.
  def test_per_source_array_sorted_with_scores
    other = Mutineer::Subject.new(file: "z.rb", namespace: ["Z"], name: :m,
                                  singleton: false, def_node: nil)
    results = [
      Mutineer::Result.killed.with(subject: subject), # pricing.rb
      survivor,                                        # pricing.rb survivor
      Mutineer::Result.killed.with(subject: other)    # z.rb
    ]
    per = render(results)["per_source"]
    assert_equal [FILE, "z.rb"], per.map { |h| h["file"] }
    pricing = per.find { |h| h["file"] == FILE }
    assert_equal 2, pricing["total"]
    assert_equal 50.0, pricing["score"]
    assert_equal 100.0, per.find { |h| h["file"] == "z.rb" }["score"]
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

  # --- matrix (schema 1.5, only with --matrix) --------------------------------

  MT_A = ["test/pricing_test.rb", "PricingTest#test_a", "PricingTest#test_a"].freeze
  MT_B = ["test/pricing_test.rb", "PricingTest#test_b", "PricingTest#test_b"].freeze
  MT_C = ["test/other_test.rb", "OtherTest#test_c", "OtherTest#test_c"].freeze

  def mt(test) = { "file" => test[0], "name" => test[1], "id" => test[2] }

  def with_row(result, killed_by, ran, complete: true)
    result.with(kills: Mutineer::Kills.new(killed_by: killed_by.sort, ran: (ran + killed_by).uniq.sort,
                                           complete: complete))
  end

  # A killed mutant both MT_A and MT_B kill, and a survivor; MT_C kills nothing.
  def matrix_results
    killed = Mutineer::Result.killed.with(subject: subject, mutation: mutation_at("100", "0", :literal_mutation),
                                          id: "killedid0001")
    [with_row(killed, [MT_A, MT_B], [MT_C]), with_row(survivor.with(id: "survivorid01"), [], [MT_A, MT_C])]
  end

  def render_matrix(results)
    out = StringIO.new
    Mutineer::Reporter.new(Mutineer::AggregateResult.new(results), { FILE => SRC },
                           matrix: Mutineer::KillMatrix.new(results))
                      .report(out: out, err: StringIO.new, format: "json")
    out.string
  end

  def test_no_matrix_key_without_the_flag
    refute render(matrix_results).key?("matrix")
  end

  def test_matrix_block_lists_tests_rows_blind_and_redundant
    m = JSON.parse(render_matrix(matrix_results))["matrix"]

    assert_equal true, m["complete"]
    assert_equal [mt(MT_C).merge("kills" => 0), mt(MT_A).merge("kills" => 1), mt(MT_B).merge("kills" => 1)],
                 m["tests"]
    # Same file and line: rows sort by operator, so the comparison survivor is first.
    assert_equal [{ "subject" => "Pricing#total", "file" => FILE, "line" => 3, "operator" => "comparison",
                    "id" => "survivorid01", "status" => "survived", "killed_by" => [], "ran" => 2, "complete" => true },
                  { "subject" => "Pricing#total", "file" => FILE, "line" => 3, "operator" => "literal_mutation",
                    "id" => "killedid0001", "status" => "killed", "killed_by" => [1, 2], "ran" => 3,
                    "complete" => true }], m["mutants"]
    assert_equal [mt(MT_C)], m["blind"]
    assert_equal [mt(MT_A), mt(MT_B)], m["redundant"]
  end

  def test_matrix_block_is_byte_stable_across_result_order
    assert_equal render_matrix(matrix_results), render_matrix(matrix_results.reverse)
  end

  def test_matrix_block_marks_an_incomplete_run
    rows = [with_row(survivor, [], [MT_A], complete: false)]
    m = JSON.parse(render_matrix(rows))["matrix"]
    assert_equal false, m["complete"]
    assert_equal false, m["mutants"].first["complete"]
    assert_empty m["blind"]
  end

end
