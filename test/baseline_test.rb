# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "tmpdir"

# #13: baseline/delta gating, tested WITHOUT Rails — a canned baseline JSON (the
# existing --format json shape) diffed against a hand-built AggregateResult.
class BaselineTest < Minitest::Test
  SRC = "class Pricing\n  def total(price)\n    if price >= 100\n    end\n  end\nend\n"
  FILE = "pricing.rb"

  def mutation_at(token, replacement, operator)
    off = SRC.index(token)
    Mutineer::Mutation.new(start_offset: off, end_offset: off + token.length,
                           replacement: replacement, operator: operator)
  end

  def subject(file = FILE)
    def_node = Mutineer::Parser.parse_string(SRC).value.statements.body.first.body.body.first
    Mutineer::Subject.new(file: file, namespace: ["Pricing"], name: :total,
                          singleton: false, def_node: def_node)
  end

  # A live survivor carrying the #10 stable id (the runner attaches it; here we set
  # it explicitly — same `Result.survived.with(...)` pattern as json_reporter_test).
  def survivor(id, token: ">=", replacement: ">", operator: :comparison, file: FILE)
    Mutineer::Result.survived.with(subject: subject(file),
                                   mutation: mutation_at(token, replacement, operator), id: id)
  end

  def agg(*results) = Mutineer::AggregateResult.new(results)

  # A baseline doc (a prior --format json run) carrying the given survivor ids.
  def baseline_doc(ids, score: nil, scoped: nil, id_format: nil, file: FILE)
    {
      # Deliberately an older schema: saved full-run 1.x reports remain valid
      # baseline inputs, per docs/json-schema.md.
      "schema_version" => "1.1",
      "summary" => { "score" => score, "scoped" => scoped, "id_format" => id_format }.compact,
      "survivors" => ids.map do |id|
        { "id" => id, "subject" => "Pricing#total", "file" => file, "line" => 3,
          "operator" => "comparison" }
      end
    }
  end

  # Acceptance 1: NEW survivor -> regression, named.
  def test_new_survivor_regresses_and_is_named
    base = Mutineer::Baseline.new(baseline_doc(%w[aaa]))
    current = agg(Mutineer::Result.killed,
                  survivor("aaa"),
                  survivor("ccc", token: "100", replacement: "0", operator: :literal_mutation))
    delta = base.diff(current)

    assert delta.regressed
    assert_equal 1, delta.new_survivors.size
    assert_equal "ccc", delta.new_survivors.first.id
  end

  # Acceptance 2: no new survivors (current subset of baseline), no drop -> pass.
  def test_subset_does_not_regress
    base = Mutineer::Baseline.new(baseline_doc(%w[aaa bbb]))
    delta = base.diff(agg(survivor("aaa")))

    refute delta.regressed
    assert_empty delta.new_survivors
    assert_equal 1, delta.fixed_survivors.size # bbb fixed (informational)
  end

  def test_empty_run_does_not_report_stored_survivors_as_fixed
    base = Mutineer::Baseline.new(baseline_doc(%w[aaa bbb]))

    delta = base.diff(agg)

    assert_empty delta.fixed_survivors
    assert_equal [%w[aaa not_run], %w[bbb not_run]], unverified(delta)
    refute delta.regressed
    refute delta.incomplete, "an empty run does not change the shared completeness rule"
    assert_empty base.diff(agg, scoped: true).fixed_survivors
    assert_empty base.diff(agg, scoped: true).unverified_survivors
  end

  def test_partial_run_reports_only_verified_fixed_survivors
    base = Mutineer::Baseline.new(baseline_doc(%w[killed ignored absent undecided]))
    current = agg(as_status(:killed, "killed"), as_status(:ignored, "ignored"),
                  as_status(:error, "undecided"))

    delta = base.diff(current, partial: true)

    assert_equal %w[killed ignored], delta.fixed_survivors.map { |h| h["id"] }
    assert_equal [%w[absent not_run], %w[undecided error]], unverified(delta)
    assert_empty base.diff(current, partial: true, scoped: true).fixed_survivors
    assert_equal %w[killed ignored absent], base.diff(current).fixed_survivors.map { |h| h["id"] }
  end

  def test_partial_run_matches_verified_fixes_in_an_old_format_baseline
    base = Mutineer::Baseline.new(baseline_doc(%w[old_killed old_ignored old_absent]))
    current = agg(as_status(:killed, "new_killed"), as_status(:ignored, "new_ignored"))
    delta = base.diff(current, partial: true,
                              id_map: { "new_killed" => "old_killed", "new_ignored" => "old_ignored" })

    assert_equal %w[old_killed old_ignored], delta.fixed_survivors.map { |h| h["id"] }
    assert_equal [%w[old_absent not_run]], unverified(delta)
  end

  def test_selected_sources_and_operators_only_limit_absent_survivors
    Dir.mktmpdir do |root|
      File.write(File.join(root, FILE), SRC)
      File.write(File.join(root, "other.rb"), SRC)
      doc = baseline_doc(%w[killed ignored omitted_source omitted_operator removed_id removed_file foreign])
      doc["survivors"].each do |entry|
        entry["file"] = "other.rb" if %w[killed ignored omitted_source].include?(entry["id"])
        entry["operator"] = "arithmetic" if %w[killed ignored omitted_operator].include?(entry["id"])
        entry["file"] = "removed.rb" if entry["id"] == "removed_file"
        entry["file"] = "/other/checkout/pricing.rb" if entry["id"] == "foreign"
      end
      base = Mutineer::Baseline.new(doc)
      delta = base.diff(agg(as_status(:killed, "killed"), as_status(:ignored, "ignored")),
                        sources: [File.join(root, ".", FILE)], operators: %w[comparison], project_root: root)

      assert_equal %w[killed ignored removed_id removed_file], delta.fixed_survivors.map { |h| h["id"] }
      assert_equal [%w[omitted_source not_run], %w[omitted_operator not_run], %w[foreign not_run]], unverified(delta)
    end
  end

  def test_missing_file_metadata_keeps_an_absent_survivor_unverified_and_a_known_kill_fixed
    Dir.mktmpdir do |root|
      File.write(File.join(root, FILE), SRC)
      doc = baseline_doc(%w[omitted known])
      doc["survivors"].each { |entry| entry.delete("file") }
      baseline_path = File.join(root, "baseline.json")
      File.write(baseline_path, JSON.generate(doc))

      delta = Mutineer::Baseline.load(baseline_path).diff(agg(as_status(:killed, "known")),
                                                       sources: [File.join(root, FILE)],
                                                       operators: %w[comparison], project_root: root)

      assert_equal [%w[omitted not_run]], unverified(delta)
      assert_equal %w[known], delta.fixed_survivors.map { |h| h["id"] }
    end
  end

  # A --since run's score covers a different denominator than a full-run
  # baseline, so scoped: true skips the score-drop half of the gate. The
  # new-survivor half (stable ids compare fine across scopes) still fires.
  def test_scoped_diff_skips_score_drop_but_keeps_new_survivor_gate
    base = Mutineer::Baseline.new(baseline_doc(%w[aaa], score: 80.0))
    current = agg(Mutineer::Result.killed, survivor("aaa")) # 50.0% vs 80.0%

    delta = base.diff(current, scoped: true)
    refute delta.score_drop, "scoped diff must not compare cross-denominator scores"
    refute delta.regressed
    assert_equal 80.0, delta.score_before # both scores still reported as facts
    assert_equal 50.0, delta.score_after

    assert base.diff(current).regressed, "same run unscoped still gates on the drop"
    assert base.diff(agg(Mutineer::Result.killed, survivor("zzz")), scoped: true).regressed,
           "a new survivor id regresses even when scoped"
  end

  # The reverse direction: a report that was itself diff-scoped, later used AS
  # the baseline, must not have its scoped score compared against a full run's.
  def test_scoped_baseline_doc_also_skips_score_drop
    scoped_base = Mutineer::Baseline.new(baseline_doc(%w[aaa], score: 90.0, scoped: true))
    current = agg(Mutineer::Result.killed, survivor("aaa")) # 50.0% full run

    delta = scoped_base.diff(current)
    refute delta.score_drop, "a scoped baseline's score must not gate a full run"
    refute delta.score_comparable
    refute delta.regressed
    assert scoped_base.diff(agg(survivor("zzz"))).regressed, "new survivors still gate"
  end

  # An out-of-scope baseline survivor was never re-tested under a diff-scoped
  # side, so it must not be reported as fixed (empty is honest, not false).
  def test_scoped_side_reports_no_fixed_survivors
    base = Mutineer::Baseline.new(baseline_doc(%w[aaa bbb]))
    scoped_delta = base.diff(agg(survivor("aaa")), scoped: true)
    assert_empty scoped_delta.fixed_survivors, "bbb was never re-tested; not fixed"

    scoped_base = Mutineer::Baseline.new(baseline_doc(%w[aaa bbb], scoped: true))
    assert_empty scoped_base.diff(agg(survivor("aaa"))).fixed_survivors

    assert_equal 1, base.diff(agg(survivor("aaa"))).fixed_survivors.size,
                 "unscoped diff still reports bbb fixed"
  end

  # Only the literal JSON boolean true marks a baseline scoped: a malformed
  # value (the STRING "false") must not silently disable the score-drop gate.
  def test_scoped_marker_requires_literal_true
    base = Mutineer::Baseline.new(baseline_doc(%w[aaa], score: 80.0, scoped: "false"))
    delta = base.diff(agg(Mutineer::Result.killed, survivor("aaa"))) # 50.0% vs 80.0%

    assert delta.score_comparable, "a non-boolean scoped value is not scoped"
    assert delta.score_drop
    assert delta.regressed
  end

  # Acceptance 3: score drop -> regression, with the "A% -> B%" facts.
  def test_score_drop_regresses
    base = Mutineer::Baseline.new(baseline_doc([], score: 80.0))
    # 3 killed / 2 survived = 60.0%, all survivors share baseline ids so only the
    # score gate fires.
    current = agg(Mutineer::Result.killed, Mutineer::Result.killed, Mutineer::Result.killed,
                  Mutineer::Result.survived, Mutineer::Result.survived)
    delta = base.diff(current)

    assert delta.score_drop
    assert delta.regressed
    assert_equal 80.0, delta.score_before
    assert_equal 60.0, delta.score_after
  end

  # nil score on either side skips the drop check (mirrors exit_code discipline).
  def test_nil_score_skips_drop_check
    base = Mutineer::Baseline.new(baseline_doc(%w[aaa], score: nil))
    current = agg(Mutineer::Result.killed, survivor("aaa")) # 50%, survivor already in baseline
    delta = base.diff(current)

    refute delta.score_drop
    refute delta.regressed
  end

  # epsilon tolerates jitter: a tiny drop within epsilon does not gate.
  def test_epsilon_tolerates_small_drop
    base = Mutineer::Baseline.new(baseline_doc([], score: 80.0))
    current = agg(*Array.new(79, Mutineer::Result.killed), *Array.new(21, Mutineer::Result.survived)) # 79%
    refute base.diff(current, epsilon: 2.0).score_drop
    assert base.diff(current, epsilon: 0.0).score_drop
  end

  # --- load() shape + error discipline (R8: ConfigError, never exit) ---

  def test_load_roundtrips_a_real_report_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "base.json")
      File.write(path, JSON.generate(baseline_doc(%w[aaa], score: 90.0)))
      base = Mutineer::Baseline.load(path)
      assert_equal 90.0, base.score
    end
  end

  def test_load_raises_config_error_on_missing_file
    assert_raises(Errno::ENOENT) { Mutineer::Baseline.load("/no/such/baseline.json") }
  end

  def test_load_raises_config_error_on_garbage
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.json")
      File.write(path, "not json {")
      assert_raises(Mutineer::ConfigError) { Mutineer::Baseline.load(path) }
    end
  end

  def test_load_raises_config_error_on_wrong_shape
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wrong.json")
      File.write(path, JSON.generate({ "hello" => "world" }))
      assert_raises(Mutineer::ConfigError) { Mutineer::Baseline.load(path) }
    end
  end

  # A scoped report is refused as a baseline: outside its diff every survivor
  # would read as NEW, so gating against it manufactures false regressions.
  def test_load_refuses_a_scoped_report_as_baseline
    Dir.mktmpdir do |dir|
      path = File.join(dir, "scoped.json")
      File.write(path, JSON.generate(baseline_doc(%w[aaa], score: 90.0, scoped: true)))
      err = assert_raises(Mutineer::ConfigError) { Mutineer::Baseline.load(path) }
      assert_match(/--since run/, err.message)
      assert_match(/full run/, err.message)
    end
  end

  # --- rendering: the delta facts reach human stdout + the additive json block ---

  def render(results, delta, format:)
    out = StringIO.new
    Mutineer::Reporter.new(agg(*results), { FILE => SRC })
                      .report(out: out, err: StringIO.new, format: format, baseline: delta)
    out.string
  end

  def test_human_report_names_new_survivor
    base = Mutineer::Baseline.new(baseline_doc([]))
    results = [Mutineer::Result.killed, survivor("ccc")]
    text = render(results, base.diff(agg(*results)), format: "human")

    assert_includes text, "1 new survivors vs baseline"
    assert_includes text, "Pricing#total (#{FILE}:3) comparison"
    assert_includes text, "REGRESSION vs baseline"
  end

  def test_human_report_prints_score_drop_line
    # Survivors already in the baseline (so only the score gate fires); rendering
    # survivors needs subjects, which survivor() carries.
    base = Mutineer::Baseline.new(baseline_doc(%w[x y], score: 80.0))
    results = [Mutineer::Result.killed, Mutineer::Result.killed, Mutineer::Result.killed,
               survivor("x"),
               survivor("y", token: "100", replacement: "0", operator: :literal_mutation)]
    text = render(results, base.diff(agg(*results)), format: "human")

    assert_includes text, "score dropped 80.0% -> 60.0%"
  end

  def test_json_report_carries_additive_baseline_block
    base = Mutineer::Baseline.new(baseline_doc([]))
    results = [Mutineer::Result.killed, survivor("ccc")]
    doc = JSON.parse(render(results, base.diff(agg(*results)), format: "json"))

    assert_equal "2.0", doc["schema_version"] # 2.0 corrects baseline semantics and includes ran_at_load_tested.
    assert doc["baseline"]["regressed"]
    assert_equal 1, doc["baseline"]["new_survivors"].size
    assert_equal "ccc", doc["baseline"]["new_survivors"].first["id"]
    # Additive comparability marker: no score on this baseline doc, so the two
    # scores must not be rendered as a comparison.
    assert_equal false, doc["baseline"]["score_comparable"]
  end

  # --- #126: baselines written before ids included the file path --------------

  # A second live survivor with its own mutation, so two survivors can differ.
  def other_survivor(id) = survivor(id, token: "100", replacement: "0", operator: :literal_mutation)

  # AE3: the same survivors, stored under their old-format ids, give no new and
  # no fixed survivors. The match through the old id is counted, not printed.
  def test_old_format_baseline_with_the_same_survivors_matches_through_legacy_ids
    base = Mutineer::Baseline.new(baseline_doc(%w[old1]))
    delta = nil
    assert_silent { delta = base.diff(agg(survivor("new1")), id_map: { "new1" => "old1" }) }

    assert_empty delta.new_survivors
    assert_empty delta.fixed_survivors
    refute delta.regressed
    assert_equal 1, delta.legacy_matches
  end

  def test_old_format_baseline_still_reports_a_genuinely_new_survivor
    base = Mutineer::Baseline.new(baseline_doc(%w[old1]))
    delta = base.diff(agg(survivor("new1"), other_survivor("new2")),
                      id_map: { "new1" => "old1", "new2" => "old2" })

    assert_equal %w[new2], delta.new_survivors.map(&:id)
    assert delta.regressed
    assert_equal 1, delta.legacy_matches
  end

  def test_old_format_baseline_still_reports_a_fixed_survivor
    base = Mutineer::Baseline.new(baseline_doc(%w[old1 old9]))
    delta = base.diff(agg(survivor("new1")), id_map: { "new1" => "old1" })

    assert_equal %w[old9], delta.fixed_survivors.map { |h| h["id"] }
  end

  # A survivor stored under its new id counts as a plain match, not a legacy one.
  def test_new_id_in_an_old_format_baseline_is_not_a_legacy_match
    base = Mutineer::Baseline.new(baseline_doc(%w[new1]))
    delta = base.diff(agg(survivor("new1")), id_map: { "new1" => "old1" })

    assert_empty delta.new_survivors
    assert_equal 0, delta.legacy_matches
  end

  # A baseline that says it uses the new format never matches on old ids.
  def test_new_format_baseline_matches_on_new_ids_only
    old_ids = Mutineer::Baseline.new(baseline_doc(%w[old1], id_format: 2))
    delta = old_ids.diff(agg(survivor("new1")), id_map: { "new1" => "old1" })
    assert_equal %w[new1], delta.new_survivors.map(&:id)
    assert_equal %w[old1], delta.fixed_survivors.map { |h| h["id"] }
    assert_equal 0, delta.legacy_matches

    new_ids = Mutineer::Baseline.new(baseline_doc(%w[new1], id_format: 2))
    delta = new_ids.diff(agg(survivor("new1")), id_map: { "new1" => "old1" })
    assert_empty delta.new_survivors
    assert_empty delta.fixed_survivors
    assert_equal 0, delta.legacy_matches
  end

  def test_scoped_diff_against_an_old_format_baseline_reports_no_fixed_survivors
    base = Mutineer::Baseline.new(baseline_doc(%w[old1 old9]))
    delta = base.diff(agg(survivor("new1")), scoped: true, id_map: { "new1" => "old1" })

    assert_empty delta.fixed_survivors
    assert_empty delta.new_survivors
  end

  # The old id has no file path, so an old-id match must also come from the same
  # file: a survivor in b.rb whose old id equals a stored survivor from FILE is a
  # different mutant and must be reported as new, not hidden.
  def test_old_format_baseline_does_not_match_an_old_id_from_another_file
    base = Mutineer::Baseline.new(baseline_doc(%w[shared_old])) # stored for FILE
    in_b = survivor("b_new", file: "lib/other.rb")
    delta = base.diff(agg(in_b), id_map: { "b_new" => "shared_old" })

    assert_equal ["b_new"], delta.new_survivors.map(&:id)
    assert_equal 0, delta.legacy_matches
    assert_equal ["shared_old"], delta.fixed_survivors.map { |h| h["id"] }
  end

  def test_old_format_baseline_matches_the_same_file_under_another_spelling
    base = Mutineer::Baseline.new(baseline_doc(%w[shared_old])) # stored as FILE
    same = survivor("a_new", file: "./#{FILE}")
    delta = base.diff(agg(same), id_map: { "a_new" => "shared_old" })

    assert_empty delta.new_survivors
    assert_equal 1, delta.legacy_matches
    assert_empty delta.fixed_survivors
  end

  # An old baseline written on another machine stores an absolute file outside
  # this project root, which can never equal the current relative file. It falls
  # back to matching on the old id alone (the pre-#126 behavior), so an unchanged
  # survivor is not a false regression.
  def test_old_format_baseline_with_a_foreign_absolute_file_matches_on_the_old_id
    base = Mutineer::Baseline.new(baseline_doc(%w[shared_old], file: "/other/checkout/pricing.rb"))
    delta = base.diff(agg(survivor("a_new")), id_map: { "a_new" => "shared_old" })

    assert_empty delta.new_survivors
    assert_equal 1, delta.legacy_matches
    assert_empty delta.fixed_survivors
  end

  # --- #283 / #286: a stored survivor is fixed only when this run decided it ---

  # A current result with the given status for a stored survivor's mutant.
  def as_status(status, id)
    Mutineer::Result.new(status: status).with(subject: subject, mutation: mutation_at(">=", ">", :comparison), id: id)
  end

  def unverified(delta) = delta.unverified_survivors.map { |h| [h["id"], h["status"]] }

  # AE1: a broken run errors every stored survivor. None is fixed, the run is
  # incomplete, and regressed keeps its meaning (no new survivor, no drop).
  def test_errored_baseline_survivors_are_unverified_not_fixed
    base = Mutineer::Baseline.new(baseline_doc(%w[a b]))
    delta = base.diff(agg(as_status(:error, "a"), as_status(:error, "b"),
                          Mutineer::Result.killed, Mutineer::Result.killed))

    assert_empty delta.fixed_survivors
    assert_equal [%w[a error], %w[b error]], unverified(delta)
    assert delta.incomplete
    refute delta.regressed
  end

  # AE2: one error in a complete run is unverified; the kill is a real fix.
  def test_one_errored_survivor_in_a_complete_run_is_unverified_and_does_not_regress
    base = Mutineer::Baseline.new(baseline_doc(%w[a b]))
    delta = base.diff(agg(as_status(:error, "a"), as_status(:killed, "b"),
                          *Array.new(20) { Mutineer::Result.killed }))

    assert_equal %w[b], delta.fixed_survivors.map { |h| h["id"] }
    assert_equal [%w[a error]], unverified(delta)
    refute delta.incomplete
    refute delta.regressed
  end

  # AE3 (#286): its tests ran and passed, so ran_at_load is not a fix.
  def test_ran_at_load_baseline_survivor_is_unverified_not_fixed
    base = Mutineer::Baseline.new(baseline_doc(%w[a]))
    delta = base.diff(agg(as_status(:ran_at_load, "a"), Mutineer::Result.killed))

    assert_empty delta.fixed_survivors
    assert_equal [%w[a ran_at_load]], unverified(delta)
  end

  # It lost its covering test: not a fix either.
  def test_no_coverage_baseline_survivor_is_unverified_not_fixed
    base = Mutineer::Baseline.new(baseline_doc(%w[a]))
    delta = base.diff(agg(as_status(:no_coverage, "a"), Mutineer::Result.killed))

    assert_empty delta.fixed_survivors
    assert_equal [%w[a no_coverage]], unverified(delta)
  end

  # A timeout or an uncapturable mutant has no verdict either: not a fix.
  def test_timeout_and_uncapturable_baseline_survivors_are_unverified_not_fixed
    base = Mutineer::Baseline.new(baseline_doc(%w[a b]))
    delta = base.diff(agg(as_status(:timeout, "a"), as_status(:uncapturable, "b"),
                          *Array.new(20) { Mutineer::Result.killed }))

    assert_empty delta.fixed_survivors
    assert_equal [%w[a timeout], %w[b uncapturable]], unverified(delta)
  end

  # The user decided it is equivalent, so it stays fixed.
  def test_ignored_baseline_survivor_still_counts_as_fixed
    base = Mutineer::Baseline.new(baseline_doc(%w[a]))
    delta = base.diff(agg(as_status(:ignored, "a"), Mutineer::Result.killed))

    assert_equal %w[a], delta.fixed_survivors.map { |h| h["id"] }
    assert_empty delta.unverified_survivors
  end

  def test_scoped_diff_lists_unverified_survivors_but_no_fixed_ones
    base = Mutineer::Baseline.new(baseline_doc(%w[a b]))
    delta = base.diff(agg(as_status(:error, "a"), Mutineer::Result.killed), scoped: true)

    assert_empty delta.fixed_survivors
    assert_equal [%w[a error]], unverified(delta)
  end

  def test_old_format_baseline_errored_survivor_is_unverified
    base = Mutineer::Baseline.new(baseline_doc(%w[old1]))
    delta = base.diff(agg(as_status(:error, "new1"), Mutineer::Result.killed), id_map: { "new1" => "old1" })

    assert_empty delta.fixed_survivors
    assert_equal [%w[old1 error]], unverified(delta)
  end

  # AE4: one error among many kills is noise, not an incomplete run.
  def test_single_error_among_many_kills_does_not_regress
    base = Mutineer::Baseline.new(baseline_doc([]))
    delta = base.diff(agg(Mutineer::Result.error, *Array.new(50) { Mutineer::Result.killed }))

    refute delta.incomplete
    refute delta.regressed
  end

  def test_human_report_names_unverified_survivors_and_an_incomplete_run
    base = Mutineer::Baseline.new(baseline_doc(%w[a b]))
    results = [as_status(:error, "a"), as_status(:error, "b"), Mutineer::Result.killed, Mutineer::Result.killed]
    text = render(results, base.diff(agg(*results)), format: "human")

    assert_includes text, "2 baseline survivors not decided this run (not killed, survived or ignored), " \
                          "so not counted as fixed:"
    assert_includes text, "  ? Pricing#total (#{FILE}:3) comparison [error]"
    assert_includes text, "incomplete run: 2 of 4 attempted mutants produced no verdict"
    assert_includes text, "INCOMPLETE vs baseline (too many mutants produced no verdict; see no_verdict[])"
    refute_includes text, "OK: no regression"
  end

  # Nothing was scored: the verdict names that, not a no-verdict share.
  def test_human_report_names_a_nil_score_incomplete_run
    base = Mutineer::Baseline.new(baseline_doc(%w[a]))
    results = [as_status(:error, "a")]
    text = render(results, base.diff(agg(*results)), format: "human")

    assert_includes text, "INCOMPLETE vs baseline (nothing could be scored; see no_verdict[])"
  end

  def test_human_report_names_both_a_regression_and_an_incomplete_run
    base = Mutineer::Baseline.new(baseline_doc([]))
    results = [Mutineer::Result.error, Mutineer::Result.error, Mutineer::Result.killed, survivor("ccc")]
    text = render(results, base.diff(agg(*results)), format: "human")

    assert_includes text, "REGRESSION and INCOMPLETE vs baseline (read no_verdict[] first)"
  end

  def test_human_report_says_when_nothing_could_be_scored
    base = Mutineer::Baseline.new(baseline_doc(%w[a]))
    results = [as_status(:error, "a")]
    text = render(results, base.diff(agg(*results)), format: "human")

    assert_includes text, "incomplete run: nothing could be scored (1 errored)"
  end

  def test_human_report_uses_the_singular_for_one_unverified_survivor
    base = Mutineer::Baseline.new(baseline_doc(%w[a b]))
    results = [as_status(:error, "a"), as_status(:killed, "b"), *Array.new(20) { Mutineer::Result.killed }]
    text = render(results, base.diff(agg(*results)), format: "human")

    assert_includes text, "1 baseline survivor not decided this run"
    refute_includes text, "incomplete run:"
    assert_includes text, "OK: no regression vs baseline"
  end

  def test_human_report_caps_the_unverified_list
    ids = Array.new(21) { |i| "s#{i}" }
    base = Mutineer::Baseline.new(baseline_doc(ids))
    results = ids.map { |id| as_status(:error, id) }
    text = render(results, base.diff(agg(*results)), format: "human")

    assert_equal 20, text.lines.count { |l| l.start_with?("  ? ") }
    assert_includes text, "  and 1 more (see baseline.unverified_survivors in --format json)"
  end

  # A hand-edited baseline can lack a field; the list still renders.
  def test_human_report_renders_an_unverified_survivor_with_missing_fields
    doc = baseline_doc(%w[a])
    doc["survivors"].first.delete("subject")
    doc["survivors"].first.delete("line")
    base = Mutineer::Baseline.new(doc)
    results = [as_status(:error, "a"), *Array.new(20) { Mutineer::Result.killed }]
    text = render(results, base.diff(agg(*results)), format: "human")

    assert_includes text, "  ?  (#{FILE}:) comparison [error]"
  end

  def test_json_baseline_block_carries_unverified_survivors_and_incomplete
    base = Mutineer::Baseline.new(baseline_doc(%w[b a]))
    results = [as_status(:error, "a"), as_status(:error, "b"), Mutineer::Result.killed, Mutineer::Result.killed]
    doc = JSON.parse(render(results, base.diff(agg(*results)), format: "json"))

    assert_equal true, doc["baseline"]["incomplete"]
    assert_equal false, doc["baseline"]["regressed"]
    assert_empty doc["baseline"]["fixed_survivors"]
    assert_equal %w[a b], doc["baseline"]["unverified_survivors"].map { |h| h["id"] }
    assert_equal({ "subject" => "Pricing#total", "file" => FILE, "line" => 3, "operator" => "comparison",
                   "id" => "a", "status" => "error" }, doc["baseline"]["unverified_survivors"].first)
  end

  # Baseline is side-effect free: it never prints, the CLI owns every warning.
  def test_diff_prints_nothing
    base = Mutineer::Baseline.new(baseline_doc(%w[aaa old1], score: 80.0))
    assert_silent do
      base.diff(agg(survivor("aaa")))
      base.diff(agg(survivor("new1")), id_map: { "new1" => "old1" })
    end
  end

  # Schema-safety: with no baseline, the doc has no `baseline` key (additive only).
  def test_no_baseline_key_without_baseline
    doc = JSON.parse(render([survivor("ccc")], nil, format: "json"))
    refute doc.key?("baseline")
  end
end
