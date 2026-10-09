# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "set"
require "stringio"
require "tmpdir"

# #10 acceptance gate: the two suppression mechanisms (inline disable-line comment
# and .mutineer.yml ignore-by-id), the :ignored exclusion from the denominator
# (100% reachable), and the JSON id round-trip. All without Rails, via the library
# API against the standalone fixtures (mirrors integration_test.rb).
class EquivalentMutantTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_mutineer(sources:, tests:, operators: nil, ignore: [])
    config = Mutineer::Config.new(
      sources: sources, tests: tests, operators: operators, ignore: ignore,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    Mutineer::Runner.execute(config)
  end

  # --- suppress_map / suppressed? unit (regex semantics, no fork) ---

  def test_suppress_map_parses_bare_and_scoped
    src = "a + b # mutineer:disable-line\n" \
          "c - d # mutineer:disable-line arithmetic, comparison\n" \
          "e * f\n"
    map = Mutineer::JobPlan.suppress_map(src, "x.rb")
    assert_equal :all, map[1][:ops]
    assert_nil map[1][:reason]
    assert_equal Set[:arithmetic, :comparison], map[2][:ops]
    assert_nil map[3]
  end

  def test_suppress_map_warns_on_an_unknown_operator
    _, err = capture_io { Mutineer::JobPlan.suppress_map("a # mutineer:disable-line comparison because\n", "x.rb") }
    assert_match(/unknown operator "comparison because" in x.rb:1 \(did you mean "comparison"\?\) \(known: .*\bcomparison\b/, err)
  end

  def test_suppress_map_suggests_a_close_operator_name
    _, err = capture_io { Mutineer::JobPlan.suppress_map("a # mutineer:disable-line comparsion\n", "x.rb") }
    assert_includes err, 'did you mean "comparison"?'
  end

  def test_suppress_map_treats_an_empty_operator_list_as_bare
    src = "a # mutineer:disable-line \nb # mutineer:disable-line  -- why\nc # mutineer:disable-line , \n"
    map = Mutineer::JobPlan.suppress_map(src, "x.rb")
    assert_equal :all, map[1][:ops]
    assert_nil map[1][:reason]
    assert_equal :all, map[2][:ops]
    assert_equal "why", map[2][:reason]
    assert_equal :all, map[3][:ops]
    assert_nil map[3][:reason]
  end

  # #158: the marker text inside a string, heredoc or regex is not a comment.
  def test_suppress_map_ignores_the_marker_inside_a_string
    src = <<~RUBY
      class Example
        def matches?(value)
          value == "# mutineer:disable-line"
        end

        def doc(x)
          x > 1 && <<~TXT
            # mutineer:disable-line
          TXT
        end

        def real(x)
          x == 1 # mutineer:disable-line comparison
        end

        def pattern(x)
          x =~ /# mutineer:disable-line/
        end
      end
    RUBY
    map = Mutineer::JobPlan.suppress_map(src, "x.rb")
    assert_equal({ 13 => { ops: Set[:comparison], reason: nil } }, map)
  end

  # PR #197 review: an =begin/=end block and the data after __END__ are not
  # line comments, so the marker text there silences nothing.
  def test_suppress_map_ignores_the_marker_in_embedded_docs_and_after_end
    src = "x = 1\n=begin\n# mutineer:disable-line\n=end\ny = 2\n__END__\nz # mutineer:disable-line\n"
    assert_empty Mutineer::JobPlan.suppress_map(src, "x.rb")
  end

  def test_suppressed_scope_matches_only_listed_operator
    disabled = { 2 => Set[:comparison] }
    refute Mutineer::JobPlan.suppressed?(:arithmetic, 2, %w[id old], disabled, Set.new)
    assert Mutineer::JobPlan.suppressed?(:comparison, 2, %w[id old], disabled, Set.new)
  end

  def test_suppressed_bare_disables_every_operator
    disabled = { 4 => :all }
    assert Mutineer::JobPlan.suppressed?(:arithmetic, 4, %w[id old], disabled, Set.new)
  end

  def test_suppressed_by_ignore_id
    assert Mutineer::JobPlan.suppressed?(:arithmetic, 1, %w[abc123 old], {}, Set["abc123"])
    refute Mutineer::JobPlan.suppressed?(:arithmetic, 1, %w[abc123 old], {}, Set["other"])
  end

  def test_suppressed_by_legacy_ignore_id
    assert Mutineer::JobPlan.suppressed?(:arithmetic, 1, %w[abc123 old], {}, Set["old"])
  end

  # --- #126: old-format ignore entries keep working, reported as data ---

  # One method in a class reopened in two files: the old id formula ignores the
  # path, so both files' first mutant share one old-format id.
  COLLIDING = "class Shared\n  def f(a) = a + 1\nend\n"

  def test_new_format_entry_suppresses_one_mutant_without_legacy_match
    with_colliding_files do |root|
      new_a = new_id(root, "a.rb")
      _, ignored, _, extras = collect(root, %w[a.rb b.rb], ignore: [new_a])
      assert_equal [new_a], ignored.map(&:id)
      assert_empty extras[:legacy_ignore_matches]
    end
  end

  def test_old_format_entry_suppresses_its_mutant_and_reports_the_new_id
    with_colliding_files do |root|
      old = legacy_id(root, "a.rb")
      _, ignored, _, extras = collect(root, %w[a.rb], ignore: [old])
      assert_equal [new_id(root, "a.rb")], ignored.map(&:id)
      assert_equal({ old => [match(root, "a.rb")] }, extras[:legacy_ignore_matches])
    end
  end

  def test_colliding_old_format_entry_suppresses_both_and_lists_both_new_ids
    with_colliding_files do |root|
      old = legacy_id(root, "a.rb")
      assert_equal old, legacy_id(root, "b.rb"), "precondition: the old ids collide"
      expected = [new_id(root, "a.rb"), new_id(root, "b.rb")]
      refute_equal expected[0], expected[1]

      _, ignored, _, extras = collect(root, %w[a.rb b.rb], ignore: [old])
      assert_equal expected, ignored.map(&:id)
      assert_equal({ old => [match(root, "a.rb"), match(root, "b.rb")] }, extras[:legacy_ignore_matches])
    end
  end

  # The old entry still over-matches b.rb even when a.rb's new id is listed, so
  # it must be reported for migration, not silently kept.
  def test_old_entry_listed_beside_its_new_id_is_still_reported
    with_colliding_files do |root|
      old = legacy_id(root, "a.rb")
      new_a = new_id(root, "a.rb")
      _, ignored, _, extras = collect(root, %w[a.rb b.rb], ignore: [new_a, old])
      assert_equal [new_a, new_id(root, "b.rb")], ignored.map(&:id)
      assert_equal({ old => [match(root, "a.rb"), match(root, "b.rb")] }, extras[:legacy_ignore_matches])
    end
  end

  def test_suppressed_accepts_a_single_id
    assert Mutineer::JobPlan.suppressed?(:arithmetic, 1, "abc123", {}, Set["abc123"])
  end

  # An inline reason is stored on the ignored result. A marker with no reason
  # stores none.
  def test_inline_reason_is_stored_on_the_ignored_result
    src = "class T\n  def f(a)\n    a + 1 # mutineer:disable-line arithmetic -- only 20 is tested\n  end\nend\n"
    bare = "class T\n  def f(a)\n    a + 1 # mutineer:disable-line arithmetic\n  end\nend\n"
    Dir.mktmpdir("mutineer-reason") do |root|
      File.write(File.join(root, "with.rb"), src)
      File.write(File.join(root, "bare.rb"), bare)
      _, with_ignored, = collect(root, %w[with.rb])
      _, bare_ignored, = collect(root, %w[bare.rb])
      assert_equal "only 20 is tested", with_ignored.first.reason
      assert_nil bare_ignored.first.reason
    end
  end

  def test_ignore_mapping_reason_is_stored_on_the_ignored_result
    with_colliding_files do |root|
      id = new_id(root, "a.rb")
      _, ignored, = collect(root, %w[a.rb], ignore: [id], ignore_reasons: { id => "same value" })
      assert_equal "same value", ignored.first.reason
    end
  end

  def test_entry_matching_nothing_is_not_a_legacy_match
    with_colliding_files do |root|
      jobs, ignored, _, extras = collect(root, %w[a.rb b.rb], ignore: ["0123456789ab"])
      assert_empty ignored
      refute_empty jobs
      assert_empty extras[:legacy_ignore_matches]
    end
  end

  def test_id_map_maps_every_new_id_to_its_legacy_id
    with_colliding_files do |root|
      old = legacy_id(root, "a.rb")
      jobs, ignored, _, extras = collect(root, %w[a.rb b.rb], ignore: [old])
      ids = jobs.map { |j| j[2] } + ignored.map(&:id)
      assert_equal ids.sort, extras[:id_map].keys.sort
      assert_equal old, extras[:id_map][new_id(root, "b.rb")]
    end
  end

  # An old entry that matched mutants in two files over-matched: the warning
  # names each new id with its file and subject, and says to keep only the ids
  # of the mutant that was meant to be ignored.
  def test_warning_for_an_entry_matching_two_files_names_both_and_warns_of_over_match
    with_colliding_files do |root|
      old = legacy_id(root, "a.rb")
      _, _, _, extras = collect(root, %w[a.rb b.rb], ignore: [old])
      _, err = capture_io { Mutineer::CLI.warn_legacy_ignore_matches(extras[:legacy_ignore_matches]) }
      assert_includes err, "#{new_id(root, 'a.rb')} (a.rb, Shared#f)"
      assert_includes err, "#{new_id(root, 'b.rb')} (b.rb, Shared#f)"
      assert_match(/over-matched: the old format could not tell these mutants apart/, err)
      assert_match(/keep only the ids for the mutant you meant to ignore/, err)
      refute_match(/Replace #{old} with the new ids/, err)
    end
  end

  def test_warning_for_an_entry_matching_one_file_has_no_over_match_wording
    with_colliding_files do |root|
      old = legacy_id(root, "a.rb")
      _, _, _, extras = collect(root, %w[a.rb], ignore: [old])
      _, err = capture_io { Mutineer::CLI.warn_legacy_ignore_matches(extras[:legacy_ignore_matches]) }
      assert_includes err, "#{new_id(root, 'a.rb')} (a.rb, Shared#f)"
      refute_match(/over-match/, err)
      assert_match(/Replace #{old} with the new ids/, err)
    end
  end

  def test_collect_jobs_prints_nothing
    with_colliding_files do |root|
      assert_output("", "") { collect(root, %w[a.rb b.rb], ignore: [legacy_id(root, "a.rb")]) }
    end
  end

  # The in-process backend reports exactly the ids collect_jobs computed.
  def test_in_process_run_carries_the_collect_jobs_ids
    sources = ["test/fixtures/calculator.rb"]
    config = Mutineer::Config.new(sources: sources, tests: [], project_root: ROOT)
    jobs, ignored, = Mutineer::JobPlan.collect_jobs(
      config, Mutineer::MutatorRegistry.resolve(Mutineer::MutatorRegistry::DEFAULT_NAMES)
    )
    agg, = run_mutineer(sources: sources, tests: ["test/fixtures/calculator_weak_test.rb"])
    assert_equal (jobs.map { |j| j[2] } + ignored.map(&:id)).sort, agg.results.map(&:id).sort
  end

  # --- Acceptance 1: inline disable-line ---

  def test_inline_disable_line_suppresses_and_reaches_100
    agg, = run_mutineer(sources: ["test/fixtures/equivalent.rb"],
                        tests: ["test/fixtures/equivalent_test.rb"],
                        operators: ["arithmetic"])

    assert_equal 0, agg.survived_count, "disable-line mutant must not survive"
    assert_equal 1, agg.ignored_count
    assert_operator agg.killed_count, :>=, 1
    assert_equal 100.0, agg.mutation_score, "suppressing the only survivor reaches 100%"

    ignored = agg.results.select(&:ignored?)
    assert_equal 1, ignored.length
    assert_equal "add", ignored.first.subject.name.to_s
    assert_equal :arithmetic, ignored.first.mutation.operator
    refute(agg.surviving_mutants.any? { |r| r.subject.name.to_s == "add" })
  end

  # --- Acceptance 2 & 3: config ignore-by-id, suppress all -> 100% ---

  def test_config_ignore_id_suppresses_one_survivor
    agg, = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                        tests: ["test/fixtures/calculator_weak_test.rb"])
    assert_equal 2, agg.survived_count
    ids = agg.surviving_mutants.map(&:id)
    assert(ids.all? { |i| i&.length == 12 }, "every survivor carries a stable id")

    agg2, = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                         tests: ["test/fixtures/calculator_weak_test.rb"],
                         ignore: [ids.first])
    assert_equal 1, agg2.survived_count
    assert_equal 1, agg2.ignored_count
    refute_includes agg2.surviving_mutants.map(&:id), ids.first
  end

  def test_suppress_all_survivors_reaches_100
    agg, = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                        tests: ["test/fixtures/calculator_weak_test.rb"])
    ids = agg.surviving_mutants.map(&:id)

    agg2, = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                         tests: ["test/fixtures/calculator_weak_test.rb"],
                         ignore: ids)
    assert_equal 0, agg2.survived_count
    assert_equal 2, agg2.ignored_count
    assert_equal 4, agg2.killed_count
    assert_equal 100.0, agg2.mutation_score
  end

  # --- Acceptance 4: JSON id round-trip ---

  def test_json_survivor_id_round_trips
    agg, source_map = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                                   tests: ["test/fixtures/calculator_weak_test.rb"])
    doc = render_json(agg, source_map)

    assert_equal "1.8", doc["schema_version"]
    assert_equal 2, doc["summary"]["survived"]
    assert_equal 0, doc["summary"]["ignored"]
    ids = doc["survivors"].map { |s| s["id"] }
    assert(ids.all? { |i| i&.length == 12 }, "every JSON survivor has a non-nil id")
    assert(doc["survivors"].all? { |s| s["token"] && !s["token"].empty? })

    agg2, sm2 = run_mutineer(sources: ["test/fixtures/calculator.rb"],
                             tests: ["test/fixtures/calculator_weak_test.rb"],
                             ignore: ids)
    doc2 = render_json(agg2, sm2)
    assert_equal 0, doc2["summary"]["survived"]
    assert_equal 2, doc2["summary"]["ignored"]
    assert_equal ids.sort, doc2["ignored"].map { |s| s["id"] }.sort
    assert_equal [], doc2["survivors"]
  end

  # Two owner-less `def index` in one file share an old id but get distinct new
  # ids (per-file ordinal). The same file passed twice under two spellings must
  # still give each declaration ONE id, not a second ordinal.
  SAME_FILE_TWICE = "describe 'a' do\n  def index(a) = a + 1\nend\n" \
                    "describe 'b' do\n  def index(a) = a + 1\nend\n"

  def test_same_file_under_two_spellings_keeps_one_id_per_declaration
    Dir.mktmpdir("mutineer-ids") do |root|
      File.write(File.join(root, "dsl.rb"), SAME_FILE_TWICE)
      once_jobs, = collect(root, %w[dsl.rb])
      twice_jobs, = collect(root, ["dsl.rb", "./dsl.rb"])
      assert_equal once_jobs.map(&:last).uniq.sort, twice_jobs.map(&:last).uniq.sort
    end
  end

  def test_same_file_collision_gets_the_keep_only_what_you_meant_advice
    Dir.mktmpdir("mutineer-ids") do |root|
      File.write(File.join(root, "dsl.rb"), SAME_FILE_TWICE)
      path = File.join(root, "dsl.rb")
      subject = Mutineer::Project.discover([path]).first
      source = File.read(path)
      old = Mutineer::MutantId.legacy_for(subject, Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first, source)
      _, _, _, extras = collect(root, %w[dsl.rb], ignore: [old])
      assert_equal 2, extras[:legacy_ignore_matches][old].map { |h| h[:id] }.uniq.size
      _, err = capture_io { Mutineer::CLI.warn_legacy_ignore_matches(extras[:legacy_ignore_matches]) }
      assert_match(/over-matched/, err)
      assert_match(/keep only the ids for the mutant you meant/, err)
    end
  end

  private

  def with_colliding_files
    Dir.mktmpdir("mutineer-ids") do |root|
      %w[a.rb b.rb].each { |f| File.write(File.join(root, f), COLLIDING) }
      yield root
    end
  end

  def collect(root, files, ignore: [], ignore_reasons: {})
    config = Mutineer::Config.new(sources: files.map { |f| File.join(root, f) }, ignore: ignore,
                                  ignore_reasons: ignore_reasons, project_root: root)
    Mutineer::JobPlan.collect_jobs(config, Mutineer::MutatorRegistry.resolve(["arithmetic"]))
  end

  # The first arithmetic mutant of `file`, as [subject, mutation, source].
  def first_mutant(root, file)
    path = File.join(root, file)
    source = File.read(path)
    subject = Mutineer::Project.discover([path]).first
    [subject, Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first, source]
  end

  def legacy_id(root, file)
    Mutineer::MutantId.legacy_for(*first_mutant(root, file))
  end

  def new_id(root, file)
    Mutineer::MutantId.for(*first_mutant(root, file), path: file)
  end

  # The legacy_ignore_matches entry for the first mutant of `file`.
  def match(root, file)
    { id: new_id(root, file), file: file, subject: "Shared#f" }
  end

  def render_json(agg, source_map)
    out = StringIO.new
    Mutineer::Reporter.new(agg, source_map).report(out: out, err: StringIO.new, format: "json")
    JSON.parse(out.string)
  end
end
