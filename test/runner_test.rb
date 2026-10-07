# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"
# Pre-require the fixture (R5/KTD4): with it already in $LOADED_FEATURES, the
# test files' `require_relative "calculator"` is a no-op in the child, so the
# child's `load(tempfile)` of the MUTATED source is not clobbered.
require_relative "fixtures/calculator"

class RunnerTest < Minitest::Test
  ROOT        = File.expand_path("..", __dir__)
  CALC        = File.expand_path("fixtures/calculator.rb", __dir__)
  STRONG_TEST = File.expand_path("fixtures/calculator_strong_test.rb", __dir__)
  WEAK_TEST   = File.expand_path("fixtures/calculator_weak_test.rb", __dir__)

  # The `+` in `add`'s body `a + b`. Offsets derived from content (not magic
  # numbers) so the test survives whitespace changes in the fixture.
  def plus_mutation(replacement: "-")
    source = File.read(CALC)
    plus = source.index("a + b") + 2 # skip "a "
    Mutineer::Mutation.new(start_offset: plus, end_offset: plus + 1,
                         replacement: replacement, operator: :arithmetic)
  end

  # A CoverageMap built over the fixture and the given test file(s), cached in a
  # throwaway dir so the run is real (Phase A subprocess) but leaves no trace.
  def coverage_map(*test_paths)
    Mutineer::CoverageMap.new(
      source_paths: [CALC], test_paths: test_paths,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    ).build_or_load
  end

  def test_mutation_killed_by_strong_suite
    result = Mutineer::Runner.run(plus_mutation, source_file: CALC, coverage_map: coverage_map(STRONG_TEST))
    assert_predicate result, :killed?, "expected killed, got #{result.status} (#{result.details})"
  end

  def test_mutation_survives_weak_suite
    result = Mutineer::Runner.run(plus_mutation, source_file: CALC, coverage_map: coverage_map(WEAK_TEST))
    assert_predicate result, :survived?, "expected survived, got #{result.status} (#{result.details})"
  end

  # The marker of the second test shows which path ran it. The first test
  # writes the seed, which the mutant run pins.
  def test_mutant_run_stops_at_first_failure_but_coverage_capture_does_not
    Dir.mktmpdir("mutineer-stop") do |dir|
      src    = File.join(dir, "stop_calc.rb")
      test   = File.join(dir, "stop_calc_test.rb")
      marker = File.join(dir, "marker")
      seed   = File.join(dir, "seed")
      File.write(src, "class StopAtFirstFailureCalculator\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(test, <<~RUBY)
        require "minitest/autorun"
        require_relative "stop_calc"
        class StopAtFirstFailureCalculatorTest < Minitest::Test
          i_suck_and_my_tests_are_order_dependent!
          def test_a_adds
            File.write(#{seed.dump}, Minitest.seed.to_s)
            assert_equal 5, StopAtFirstFailureCalculator.new.add(2, 3)
          end
          def test_b_writes_marker
            File.write(#{marker.dump}, "ran")
            pass
          end
        end
      RUBY
      map = Mutineer::CoverageMap.new(source_paths: [src], test_paths: [test],
                                      cache_dir: File.join(dir, "cache"), project_root: dir).build_or_load
      assert_path_exists marker, "coverage capture must run every test"

      File.delete(marker)
      require src # R5/KTD4: keep the child's require_relative from reloading it
      plus = File.read(src).index("a + b") + 2
      mutation = Mutineer::Mutation.new(start_offset: plus, end_offset: plus + 1,
                                        replacement: "-", operator: :arithmetic)
      result = Mutineer::Runner.run(mutation, source_file: src, coverage_map: map)

      assert_predicate result, :killed?, "expected killed, got #{result.status} (#{result.details})"
      refute_path_exists marker, "the mutant run must stop at the first failing test"
      pinned = ENV["SEED"] ? ENV["SEED"].to_i % 0xFFFF : Mutineer::MinitestIntegration::STOP_AT_FIRST_FAILURE_SEED
      assert_equal pinned.to_s, File.read(seed)
    end
  end

  # #203: only the fast file kills the mutant, and the slow file sleeps past
  # the timeout. The map lists the slow file first, but the recorded timings
  # run the fast file first, so the run stops at its failure.
  def test_cheapest_covering_file_runs_first_so_a_fast_kill_beats_the_timeout
    Dir.mktmpdir("mutineer-order") do |dir|
      src = File.join(dir, "order_calc.rb")
      File.write(src, "class CostOrderCalculator\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(File.join(dir, "a_slow_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "order_calc"
        class ASlowCostOrderTest < Minitest::Test
          def test_slow
            sleep 60
            CostOrderCalculator.new.add(2, 3)
          end
        end
      RUBY
      File.write(File.join(dir, "z_fast_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "order_calc"
        class ZFastCostOrderTest < Minitest::Test
          def test_add
            assert_equal 5, CostOrderCalculator.new.add(2, 3)
          end
        end
      RUBY
      require src # R5/KTD4: keep the child's require_relative from reloading it
      map = Mutineer::CoverageMap.from_data(
        map: { "order_calc.rb:3" => %w[a_slow_test.rb z_fast_test.rb] }, failed_test_files: [],
        project_root: dir, timings: { "a_slow_test.rb" => 8.0, "z_fast_test.rb" => 1.0 }
      )
      plus = File.read(src).index("a + b") + 2
      mutation = Mutineer::Mutation.new(start_offset: plus, end_offset: plus + 1,
                                        replacement: "-", operator: :arithmetic)

      result = Mutineer::Runner.run(mutation, source_file: src, coverage_map: map, timeout: 5)
      assert_predicate result, :killed?, "expected killed, got #{result.status} (#{result.details})"
    end
  end

  def run_slow_suite(**limits)
    Dir.mktmpdir("mutineer-limits") do |dir|
      src  = File.join(dir, "slow_calc.rb")
      test = File.join(dir, "slow_calc_test.rb")
      File.write(src, "class SlowLimitCalculator\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(test, <<~RUBY)
        require "minitest/autorun"
        require_relative "slow_calc"
        class SlowLimitCalculatorTest < Minitest::Test
          def test_add
            sleep 1.5
            assert_equal 5, SlowLimitCalculator.new.add(2, 3)
          end
        end
      RUBY
      config = Mutineer::Config.new(sources: [src], tests: [test], operators: ["arithmetic"], jobs: 1,
                                    cache_dir: File.join(dir, "cache"), project_root: dir, **limits)
      Mutineer::Runner.execute(config).first
    end
  end

  def test_timeout_bounds_each_mutant_run
    agg = run_slow_suite(timeout: 1)
    assert_equal 0, agg.killed_count
    assert_operator agg.timeout_count, :>, 0
  end

  def test_capture_timeout_bounds_coverage_capture
    error = assert_raises(Mutineer::SmokeCheckError) { run_slow_suite(capture_timeout: 1) }
    assert_includes error.message, "capture failed for slow_calc_test.rb"
  end

  def test_syntactically_invalid_mutation_is_skipped
    # Replacing `+` with `)` makes `a ) b` — unparseable, so no fork happens.
    result = Mutineer::Runner.run(plus_mutation(replacement: ")"),
                                source_file: CALC, coverage_map: coverage_map(STRONG_TEST))
    assert_predicate result, :skipped?, "expected skipped, got #{result.status}"
  end

  def test_collect_jobs_emits_a_nested_method_mutant_once_on_the_inner_subject
    Dir.mktmpdir do |root|
      path = File.join(root, "nested.rb")
      File.write(path, "class Nested\n  def outer\n    def inner\n      true\n    end\n    false\n  end\nend\n")
      config = Mutineer::Config.new(sources: [path], project_root: root)
      jobs, = Mutineer::JobPlan.collect_jobs(config, Mutineer::MutatorRegistry.resolve(Mutineer::MutatorRegistry::ALL.keys))

      edits = jobs.map { |_s, m, _id| [m.start_offset, m.end_offset, m.replacement] }
      assert_equal edits.uniq, edits, "an edit is emitted on more than one subject"
      owners = jobs.select { |_s, m, _id| m.operator == :boolean_literal && m.replacement == "false" }
                   .map { |s, _m, _id| s.qualified_name }
      assert_equal ["Nested#inner"], owners
    end
  end

  def test_collect_jobs_keeps_a_def_in_class_shift_obj_on_the_enclosing_subject
    Dir.mktmpdir do |root|
      path = File.join(root, "nested.rb")
      File.write(path, "class Nested\n  def outer(obj)\n    class << obj\n      def hidden\n        true\n      end\n    end\n" \
                       "    class << self\n      def shown\n        true\n      end\n    end\n  end\nend\n")
      config = Mutineer::Config.new(sources: [path], project_root: root)
      jobs, = Mutineer::JobPlan.collect_jobs(config, Mutineer::MutatorRegistry.resolve(Mutineer::MutatorRegistry::ALL.keys))

      edits = jobs.map { |_s, m, _id| [m.start_offset, m.end_offset, m.replacement] }
      assert_equal edits.uniq, edits, "an edit is emitted on more than one subject"
      owners = jobs.select { |_s, m, _id| m.operator == :boolean_literal && m.replacement == "false" }
                   .map { |s, _m, _id| s.qualified_name }
      assert_equal ["Nested#outer", "Nested.shown"], owners.sort
    end
  end

  FakeCoverageMap = Struct.new(:tests_by_line, :project_root, :load_lines, :uncapturable) do
    def tests_for(_file, line) = tests_by_line.fetch(line, [])
    def method_uncapturable?(*) = uncapturable || false
    def ran_at_load?(_file, line) = Array(load_lines).include?(line)
    def order_tests(_file, tests) = tests
  end

  def selection(source, snippet, tests_by_line, load_lines: [], uncapturable: false)
    def_node = Mutineer::Parser.parse_string(source).value.statements.body.first
    subject = Mutineer::Subject.new(file: "x.rb", namespace: [], name: :f, singleton: false, def_node: def_node)
    start = source.index(snippet)
    mutation = Mutineer::Mutation.new(start_offset: start, end_offset: start + snippet.size,
                                      replacement: "nil", operator: :test)
    Mutineer::JobPlan.coverage_selection("x.rb", mutation, subject, source,
                                        FakeCoverageMap.new(tests_by_line, "/root", load_lines, uncapturable))
  end

  # #187: an uncovered line that ran at load is ran_at_load, not no_coverage;
  # a lost capture still wins, since that is a broken harness.
  def test_coverage_selection_order_is_uncapturable_then_ran_at_load_then_no_coverage
    source = "def f(x)\n  x * 2\nend\n"

    assert_equal :no_coverage, selection(source, "x * 2", {})[1].status
    assert_equal :ran_at_load, selection(source, "x * 2", {}, load_lines: [2])[1].status
    assert_equal :uncapturable, selection(source, "x * 2", {}, load_lines: [2], uncapturable: true)[1].status
  end

  # #187: `x if c` counts its line when `c` is checked, also when `x` never
  # runs, so a mutant in `x` did not run at load.
  def test_coverage_selection_does_not_count_code_that_runs_only_sometimes
    source = "def f(k)\n  return 7 * 6 if k.nil?\n  k\nend\n"
    assert_equal :no_coverage, selection(source, "7 * 6", {}, load_lines: [2])[1].status
  end

  # #187: the def line counts when the method is defined, so it is never a load
  # line; a one-line def is the documented known limit.
  def test_coverage_selection_ignores_the_def_line_load_count
    assert_equal :no_coverage, selection("def f(x = 1)\n  x\nend\n", "1", {}, load_lines: [1])[1].status
    assert_equal :no_coverage, selection("def f(x) = x * 2\n", "x * 2", {}, load_lines: [1])[1].status
  end

  def test_coverage_selection_uses_the_tests_that_ran_the_whole_statement
    source = <<~RUBY
      def f(c)
        {
          yes: c.fetch(true, 0),
          no: c.fetch(false, 0)
        }
      end
    RUBY
    kind, tests = selection(source, "false", { 3 => ["t_test.rb"] })

    assert_equal :run, kind
    assert_equal ["/root/t_test.rb"], tests
  end

  def test_coverage_selection_gives_a_statement_that_did_not_run_no_tests
    source = <<~RUBY
      def f(c)
        c ||
          false
      end
    RUBY
    kind, = selection(source, "false", {})

    assert_equal :verdict, kind
  end

  # --since restricts the job list to mutations on changed lines. Deterministic:
  # stub ChangedLines.for (no real git) so only line 5 (`a + b`) is "changed",
  # then assert filter_since keeps only line-5 jobs and drops the rest.
  def test_filter_since_keeps_only_jobs_on_changed_lines
    config = Mutineer::Config.new(sources: [CALC], project_root: ROOT, since: "HEAD~1")
    source_map = { CALC => File.read(CALC) }
    jobs = build_jobs(config, source_map)

    lines = jobs.map { |_s, m| line_of(m, source_map[CALC]) }.uniq
    assert_includes lines, 5
    assert_operator lines.length, :>, 1, "fixture should yield mutations on several lines"

    Mutineer::ChangedLines.stub(:for, { CALC => Set[5] }) do
      kept = Mutineer::JobPlan.filter_since(jobs, source_map, config)
      assert kept.length.positive?, "line 5 mutations should survive"
      assert kept.length < jobs.length, "off-line mutations should be filtered out"
      assert(kept.all? { |_s, m| line_of(m, source_map[CALC]) == 5 })
    end
  end

  def test_filter_since_file_absent_from_diff_yields_no_jobs
    config = Mutineer::Config.new(sources: [CALC], project_root: ROOT, since: "HEAD~1")
    source_map = { CALC => File.read(CALC) }
    jobs = build_jobs(config, source_map)

    Mutineer::ChangedLines.stub(:for, {}) do
      assert_empty Mutineer::JobPlan.filter_since(jobs, source_map, config)
    end
  end

  # #7: --rails with an unset RAILS_ENV defaults to "test"; explicit is respected.
  def test_ensure_rails_env_defaults_to_test_when_unset
    with_rails_env(nil) do
      Mutineer::Runner.ensure_rails_env(Mutineer::Config.new(rails: true))
      assert_equal "test", ENV.fetch("RAILS_ENV")
    end
  end

  def test_ensure_rails_env_respects_explicit_value
    with_rails_env("staging") do
      Mutineer::Runner.ensure_rails_env(Mutineer::Config.new(rails: true))
      assert_equal "staging", ENV.fetch("RAILS_ENV")
    end
  end

  def test_ensure_rails_env_noop_without_rails
    with_rails_env(nil) do
      Mutineer::Runner.ensure_rails_env(Mutineer::Config.new(rails: false))
      assert_nil ENV["RAILS_ENV"]
    end
  end

  # #8: reconnect decision predicate — proven WITHOUT Rails via injected doubles.
  # A plain object exposing connection_pool (active_connection?) and connection
  # (open_transactions) stands in for ActiveRecord::Base.
  Pool = Struct.new(:active)        { def active_connection? = active }
  Conn = Struct.new(:open_txns)     { def open_transactions = open_txns }
  Base = Struct.new(:connection_pool, :connection)

  def fto?(base) = Mutineer::Runner.send(:fixture_transaction_open?, base)

  # open_transactions == 1, active -> true (reconnect skips the clear, preserving
  # the fixture transaction so write-heavy tests keep their fixture rows).
  def test_fixture_transaction_open_when_active_and_in_transaction
    assert fto?(Base.new(Pool.new(true), Conn.new(1)))
  end

  # open_transactions == 0, active -> false (clear runs; v0.2 write-safety intact).
  def test_fixture_transaction_not_open_when_no_transaction
    refute fto?(Base.new(Pool.new(true), Conn.new(0)))
  end

  # no active connection -> false (nothing to preserve; clear).
  def test_fixture_transaction_not_open_when_no_active_connection
    refute fto?(Base.new(Pool.new(false), Conn.new(1)))
  end

  # probe raises -> false (safe default = clear, existing behaviour).
  def test_fixture_transaction_open_safe_defaults_to_false_on_error
    boom = Object.new
    def boom.connection_pool = raise("no pool")
    refute fto?(boom)
  end

  def test_abort_if_unclean_raises_when_no_test_recorded_coverage
    map = Mutineer::CoverageMap.from_data(map: {}, failed_test_files: ["test/calc_test.rb"], project_root: ROOT)
    err = assert_raises(Mutineer::SmokeCheckError) { Mutineer::JobPlan.abort_if_unclean!(map) }
    assert_match(%r{capture failed for test/calc_test\.rb}, err.message)
  end

  def test_abort_if_unclean_passes_when_another_test_recorded_coverage
    map = Mutineer::CoverageMap.from_data(map: { "lib/calc.rb:2" => ["test/ok_test.rb"] },
                                          failed_test_files: ["test/calc_test.rb"], project_root: ROOT)
    assert_nil Mutineer::JobPlan.abort_if_unclean!(map)
  end

  # #159: an operator that emits one edit twice runs it once, and every kept
  # mutant keeps the id it had before (ids are assigned before the drop, so a
  # dropped copy's id is never handed to the next twin).
  def test_collect_jobs_runs_a_repeated_edit_once_and_keeps_ids
    Dir.mktmpdir do |dir|
      path = File.join(dir, "zero.rb")
      File.write(path, "class Zero\n  def a\n    x = 0\n    y = 0\n    !!x\n  end\nend\n")
      config = Mutineer::Config.new(sources: [path], project_root: dir)
      ops = Mutineer::MutatorRegistry.resolve(%w[literal_mutation negation_removal])
      jobs, _ignored, _map, extras = Mutineer::JobPlan.collect_jobs(config, ops)

      source = File.read(path)
      mutated = jobs.map { |_s, m, _id| [m.operator, m.apply(source)] }
      assert_equal mutated.uniq, mutated
      assert_equal 3, jobs.size # x = 1, y = 1, !x

      subject = jobs.first[0]
      all = ops.flat_map { |k| k.new.mutations_for(subject, source) }
      before = Mutineer::MutantId.for_subject(subject, source, all, path: "zero.rb")
      lines = all.map { |m| source.byteslice(0, m.start_offset).count("\n") + 1 }
      keys = Mutineer::JobPlan.result_keys(all, source, lines)
      kept = all.each_index.select { |i| keys.index(keys[i]) == i }
      assert_equal kept.map { |i| before[i] }, jobs.map(&:last)

      # PR #198 review: a dropped copy records nothing in the id map either.
      dropped = (all.each_index.to_a - kept).map { |i| before[i] }
      refute_empty dropped
      assert_empty dropped & extras[:id_map].keys
      assert_equal 3, extras[:id_map].size
    end
  end

  # PR #198 review: operand_removal on `x || x` keeps either side, which gives
  # the same source; it runs once and keeps its id.
  def test_collect_jobs_runs_a_repeated_operand_removal_once
    Dir.mktmpdir do |dir|
      path = File.join(dir, "either.rb")
      File.write(path, "class Either\n  def a(x)\n    x || x\n  end\nend\n")
      config = Mutineer::Config.new(sources: [path], project_root: dir)
      ops = Mutineer::MutatorRegistry.resolve(%w[operand_removal])
      jobs, = Mutineer::JobPlan.collect_jobs(config, ops)
      source = File.read(path)
      all = ops.first.new.mutations_for(jobs.first[0], source)
      assert_equal 2, all.size, "operand_removal emits both sides"
      assert_equal 1, jobs.size
      first_id = Mutineer::MutantId.for_subject(jobs.first[0], source, all, path: "either.rb").first
      assert_equal first_id, jobs.first.last
    end
  end

  # #159: copies of one edit that start on different lines both stay, so a
  # line-based filter such as --since never loses the edit.
  def test_collect_jobs_keeps_copies_on_different_lines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chain.rb")
      File.write(path, "class Chain\n  def m\n    a\n      .b\n      .b\n      .c\n  end\nend\n")
      config = Mutineer::Config.new(sources: [path], project_root: dir)
      jobs, = Mutineer::JobPlan.collect_jobs(config, Mutineer::MutatorRegistry.resolve(%w[chain_link]))
      assert_equal 2, jobs.size
    end
  end

  # #159: an ignore entry for one copy's id does not hide the other copy of the
  # same edit. The copies are dropped separately among run and ignored mutants.
  def test_collect_jobs_keeps_an_unsuppressed_copy_of_a_suppressed_edit
    Dir.mktmpdir do |dir|
      path = File.join(dir, "zero.rb")
      File.write(path, "class Zero\n  def a\n    0\n  end\nend\n")
      ops = Mutineer::MutatorRegistry.resolve(%w[literal_mutation])
      first_id = Mutineer::JobPlan.collect_jobs(Mutineer::Config.new(sources: [path], project_root: dir), ops)
                                 .first.first.last
      config = Mutineer::Config.new(sources: [path], project_root: dir, ignore: [first_id])
      jobs, ignored, = Mutineer::JobPlan.collect_jobs(config, ops)
      assert_equal [first_id], ignored.map(&:id)
      assert_equal 1, jobs.size
      refute_equal first_id, jobs.first.last
    end
  end

  # Every row of a large matrix names the same tests; after share_tests they
  # are one frozen array per test, whatever row they came from.
  def test_share_tests_gives_every_row_the_same_test_objects
    row = lambda do |status|
      test = ["t_test.rb".dup, "T#test_a".dup, "T#test_a".dup]
      kills = Mutineer::Kills.new(killed_by: status == :killed ? [test] : [], ran: [test.dup], complete: true)
      Mutineer::Result.new(status: status, kills: kills)
    end
    shared = Mutineer::Runner.share_tests([row.(:killed), row.(:survived), Mutineer::Result.no_coverage])

    assert_same shared[0].kills.ran.first, shared[1].kills.ran.first
    assert_same shared[0].kills.killed_by.first, shared[0].kills.ran.first
    assert_predicate shared[0].kills.ran.first, :frozen?
    assert_nil shared[2].kills
  end

  # A test is its file and id. An example worded from its matcher has a new
  # name under each mutant, and it stays one test under the first name.
  def test_share_tests_keeps_one_test_when_only_the_name_changes
    row = lambda do |name|
      test = ["s_spec.rb", name, "./s_spec.rb[1:1]"]
      Mutineer::Result.new(status: :survived, kills: Mutineer::Kills.new(killed_by: [], ran: [test], complete: true))
    end
    shared = Mutineer::Runner.share_tests([row.("is expected to eq 1"), row.("is expected to eq -1")])

    assert_equal [["s_spec.rb", "is expected to eq 1", "./s_spec.rb[1:1]"]], shared.flat_map { |r| r.kills.ran }.uniq
  end

  # parallelize_me! queues every test before the first one fails, so the run
  # without --matrix cannot stop at test_a's failure and reaches the timeout
  # while test_b loops. The matrix keeps that verdict.
  def test_matrix_keeps_the_timeout_of_a_parallel_run
    looper = File.expand_path("fixtures/matrix/looper.rb", __dir__)
    looper_test = File.expand_path("fixtures/matrix/looper_parallel_test.rb", __dir__)
    require looper # R5/KTD4: keep the child's require_relative from reloading it
    map = Mutineer::CoverageMap.new(source_paths: [looper], test_paths: [looper_test],
                                    cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT).build_or_load
    plus = File.read(looper).index("i + 1") + 2
    mutation = Mutineer::Mutation.new(start_offset: plus, end_offset: plus + 1, replacement: "-", operator: :arithmetic)

    plain = Mutineer::Runner.run(mutation, source_file: looper, coverage_map: map, timeout: 2)
    matrix = Mutineer::Runner.run(mutation, source_file: looper, coverage_map: map, timeout: 2, matrix: true)

    assert_predicate plain, :timeout?
    assert_predicate matrix, :timeout?
    assert_equal ["MatrixLooperParallelTest#test_a_next"], matrix.kills.killed_by.map { |_file, name, _id| name }
    refute matrix.kills.complete
  end

  # #191 review: under --matrix, an error with no row (a crashed worker, a
  # lost result) gets an empty, incomplete row, so the report warns about it.
  # Other results keep what they have: a no-coverage mutant never ran.
  def test_unreported_row_marks_an_error_without_a_row_incomplete
    row = Mutineer::Runner.unreported_row(Mutineer::Result.error("worker crashed: boom")).kills
    assert_equal [[], [], false], [row.killed_by, row.ran, row.complete]
    assert_nil Mutineer::Runner.unreported_row(Mutineer::Result.no_coverage).kills
    kept = Mutineer::Kills.new(killed_by: [], ran: [], complete: true)
    assert_same kept, Mutineer::Runner.unreported_row(Mutineer::Result.survived.with(kills: kept)).kills
  end

  private

  def with_rails_env(value)
    orig = ENV["RAILS_ENV"]
    value.nil? ? ENV.delete("RAILS_ENV") : (ENV["RAILS_ENV"] = value)
    yield
  ensure
    orig.nil? ? ENV.delete("RAILS_ENV") : (ENV["RAILS_ENV"] = orig)
  end

  def line_of(mutation, source)
    source.byteslice(0, mutation.start_offset).count("\n") + 1
  end

  def build_jobs(config, source_map)
    klass = Mutineer::MutatorRegistry.resolve(["arithmetic"]).first
    jobs = []
    Mutineer::Project.discover(config.sources).each do |subject|
      source = source_map[subject.file]
      klass.new.mutations_for(subject, source).each { |m| jobs << [subject, m] }
    end
    jobs
  end
end
