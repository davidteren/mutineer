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

  def subject
    def_node = Mutineer::Parser.parse_string(SRC).value.statements.body.first.body.body.first
    Mutineer::Subject.new(file: FILE, namespace: ["Pricing"], name: :total,
                          singleton: false, def_node: def_node)
  end

  # A live survivor carrying the #10 stable id (the runner attaches it; here we set
  # it explicitly — same `Result.survived.with(...)` pattern as json_reporter_test).
  def survivor(id, token: ">=", replacement: ">", operator: :comparison)
    Mutineer::Result.survived.with(subject: subject,
                                   mutation: mutation_at(token, replacement, operator), id: id)
  end

  def agg(*results) = Mutineer::AggregateResult.new(results)

  # A baseline doc (a prior --format json run) carrying the given survivor ids.
  def baseline_doc(ids, score: nil, scoped: nil)
    {
      # Deliberately an older schema: a baseline written by a prior version must
      # still be readable, per the "accept any 1.x" contract in docs/json-schema.md.
      "schema_version" => "1.1",
      "summary" => { "score" => score, "scoped" => scoped }.compact,
      "survivors" => ids.map do |id|
        { "id" => id, "subject" => "Pricing#total", "file" => FILE, "line" => 3,
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

    assert_equal "1.2", doc["schema_version"] # the baseline block alone does not move it
    assert doc["baseline"]["regressed"]
    assert_equal 1, doc["baseline"]["new_survivors"].size
    assert_equal "ccc", doc["baseline"]["new_survivors"].first["id"]
    # Additive comparability marker: no score on this baseline doc, so the two
    # scores must not be rendered as a comparison.
    assert_equal false, doc["baseline"]["score_comparable"]
  end

  # Schema-safety: with no baseline, the doc has no `baseline` key (additive only).
  def test_no_baseline_key_without_baseline
    doc = JSON.parse(render([survivor("ccc")], nil, format: "json"))
    refute doc.key?("baseline")
  end
end
