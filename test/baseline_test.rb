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
  def baseline_doc(ids, score: nil)
    {
      "schema_version" => "1.1",
      "summary" => { "score" => score },
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

    assert_equal "1.1", doc["schema_version"] # schema unchanged
    assert doc["baseline"]["regressed"]
    assert_equal 1, doc["baseline"]["new_survivors"].size
    assert_equal "ccc", doc["baseline"]["new_survivors"].first["id"]
  end

  # Schema-safety: with no baseline, the doc has no `baseline` key (additive only).
  def test_no_baseline_key_without_baseline
    doc = JSON.parse(render([survivor("ccc")], nil, format: "json"))
    refute doc.key?("baseline")
  end
end
