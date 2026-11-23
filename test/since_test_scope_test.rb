# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"

# #496: with `since_paired_tests`, a `--since` run uses only the tests paired
# with the sources that have a mutant on a changed line. Every source still
# loads. The repro of #496 is kept inline, as since_empty_run_test.rb keeps the
# #396 repro: two sources, two tests, one changed line in the first source.
class SinceTestScopeTest < Minitest::Test
  OPS = ["arithmetic"].freeze
  Subject = Struct.new(:file)

  # --- JobPlan.since_tests: the rule over many inputs ---------------------

  ROOT = "/proj"
  ROWS = {
    "lib/a.rb" => ["test/a_test.rb", "test/shared_test.rb"],
    "lib/b.rb" => ["test/b_test.rb", "test/shared_test.rb"],
    "lib/c.rb" => ["test/c_test.rb"]
  }.freeze
  ALL_TESTS = %w[test/a_test.rb test/b_test.rb test/c_test.rb test/shared_test.rb].freeze

  def test_since_tests_keeps_the_rows_of_the_live_sources_in_full_list_order
    cases = {
      "one live source" => [%w[lib/a.rb], {}, %w[test/a_test.rb test/shared_test.rb]],
      "two live sources" => [%w[lib/c.rb lib/a.rb], {}, %w[test/a_test.rb test/c_test.rb test/shared_test.rb]],
      "every source live" => [%w[lib/a.rb lib/b.rb lib/c.rb], {}, ALL_TESTS],
      "absolute subject path" => [["#{ROOT}/lib/b.rb"], {}, %w[test/b_test.rb test/shared_test.rb]],
      "dotted subject path" => [%w[./lib/c.rb], {}, %w[test/c_test.rb]],
      "setting off" => [%w[lib/a.rb], { since_paired_tests: false }, ALL_TESTS],
      "no --since" => [%w[lib/a.rb], { since: nil }, ALL_TESTS],
      "no pairing rows" => [%w[lib/a.rb], { tests_by_source: {} }, ALL_TESTS],
      "--coverage-from reused by a boot run" => [%w[lib/a.rb], { coverage_from: "cov.json", boot: "boot.rb" }, ALL_TESTS],
      "--coverage-from ignored without a boot" => [%w[lib/a.rb], { coverage_from: "cov.json" },
                                                    %w[test/a_test.rb test/shared_test.rb]],
      "--coverage-from ignored by --daemon" => [%w[lib/a.rb], { coverage_from: "cov.json", boot: "b.rb", daemon: true },
                                                 %w[test/a_test.rb test/shared_test.rb]],
      "live source with no row" => [%w[lib/a.rb lib/other.rb], {}, ALL_TESTS],
      "--baseline set (#552 item 3)" => [%w[lib/a.rb], { baseline: "base.json" }, ALL_TESTS],
      "--baseline set, every live source" => [%w[lib/a.rb lib/b.rb lib/c.rb], { baseline: "base.json" }, ALL_TESTS],
      "no jobs" => [[], {}, ALL_TESTS]
    }
    cases.each do |label, (files, overrides, expected)|
      config = scope_config(**overrides)
      jobs = files.each_with_index.map { |file, i| [Subject.new(file), nil, "id#{i}"] }
      assert_equal expected, Mutineer::JobPlan.since_tests(config, jobs), label
    end
  end

  def test_narrow_tests_for_since_returns_the_same_config_when_nothing_narrows
    config = scope_config
    jobs = [[Subject.new("lib/a.rb"), nil, "x"], [Subject.new("lib/b.rb"), nil, "y"], [Subject.new("lib/c.rb"), nil, "z"]]
    out, err = capture_io { assert_same config, Mutineer::JobPlan.narrow_tests_for_since(config, jobs) }
    assert_empty out
    assert_empty err
  end

  # #552 item 3: a narrowed run can hide a new survivor as no_coverage, which
  # the --baseline check leaves out, so a baseline keeps the full list. The
  # same config without a baseline narrows.
  def test_a_baseline_turns_narrowing_off
    jobs = [[Subject.new("lib/c.rb"), nil, "x"]]
    config = scope_config(baseline: "base.json")
    _out, err = capture_io { assert_same config, Mutineer::JobPlan.narrow_tests_for_since(config, jobs) }
    assert_empty err
    assert_equal ALL_TESTS, config.tests
    capture_io { assert_equal %w[test/c_test.rb], Mutineer::JobPlan.narrow_tests_for_since(scope_config, jobs).tests }
  end

  def test_narrow_tests_for_since_copies_the_config_and_keeps_every_source
    config = scope_config
    jobs = [[Subject.new("lib/c.rb"), nil, "x"], [Subject.new("lib/c.rb"), nil, "y"]]
    narrowed = nil
    _out, err = capture_io { narrowed = Mutineer::JobPlan.narrow_tests_for_since(config, jobs) }
    refute_same config, narrowed
    assert_equal %w[test/c_test.rb], narrowed.tests
    assert_equal ALL_TESTS, config.tests, "the caller's config keeps the full list"
    assert_equal ROWS.keys, narrowed.sources
    assert_equal "[mutineer] --since: running 1 of 4 test files, the ones paired with the 1 of 3 paired " \
                 "sources that has a mutant on a changed line. A mutant that only another test reaches " \
                 "shows as survived or no_coverage, so a kill or a survivor can be missed. no_coverage is outside the " \
                 "score, so a --threshold gate can pass where a full run fails: gate on a full run. A --baseline run " \
                 "keeps every test.\n", err
  end

  def test_narrowing_line_for_one_and_for_many
    {
      [1, 2, 1, 2] => "running 1 of 2 test files, the ones paired with the 1 of 2 paired sources that has a",
      [14, 281, 8, 120] => "running 14 of 281 test files, the ones paired with the 8 of 120 paired sources that have a"
    }.each do |counts, fragment|
      line = Mutineer::JobPlan.since_narrowing_line(*counts)
      assert line.start_with?("[mutineer] --since: #{fragment} mutant on a changed line."), line
      assert line.end_with?("so a kill or a survivor can be missed. no_coverage is outside the score, so a " \
                            "--threshold gate can pass where a full run fails: gate on a full run. A --baseline " \
                            "run keeps every test."), line
    end
  end

  # --- A real run: the #496 repro -----------------------------------------

  # AE1: standalone (build_or_load) and boot (build_via_fork) shapes, reload
  # and redefine. b_test.rb never loads, and the map names a_test.rb for the
  # changed line, so a_test.rb is the test that kills the mutant.
  def test_since_paired_tests_captures_only_the_tests_of_the_changed_source
    with_repo do |dir, a_src, b_src, a_test, b_test|
      boot = File.join(dir, "boot.rb")
      # The boot loads every source, as an app boot does. A test then loads
      # no source itself, so a reload child keeps its mutant.
      File.write(boot, "require_relative \"a\"\nrequire_relative \"b\"\n")
      [boot, nil].each do |boot_path|
        %w[reload redefine].each do |strategy|
          label = "#{boot_path ? 'boot' : 'standalone'} #{strategy}"
          clear_markers(dir)
          config = run_config(dir, [a_src, b_src], [a_test, b_test], strategy: strategy, boot: boot_path,
                                                                     cache: "cache-#{label.tr(' ', '-')}")
          aggregate, maps, err = run_and_capture_map(config)

          refute_path_exists marker(dir, "b"), "#{label}: b_test.rb must not load"
          assert_path_exists marker(dir, "a"), label
          assert_includes err, "running 1 of 2 test files", label
          assert_includes err, "the 1 of 2 paired sources that has a mutant on a changed line", label
          refute_equal 0, aggregate.killed_count, "#{label}: #{aggregate.results.map { |r| [r.status, r.details] }.inspect}"
          assert_equal aggregate.results.size, aggregate.killed_count, label
          line = File.read(a_src).lines.index { |l| l.include?("# touched") } + 1
          assert_equal ["a_test.rb"], maps.last.tests_for(a_src, line), label
          assert_equal %w[a.rb b.rb], maps.last.instance_variable_get(:@source_paths).map { |s| File.basename(s) }.sort,
                       "#{label}: every source stays in the map and its cache key"
        end
      end
    end
  end

  # KTD6: a second narrowed run with the same changed source hits its cache.
  def test_a_second_narrowed_run_hits_the_narrowed_cache
    with_repo do |dir, a_src, b_src, a_test, b_test|
      config = -> { run_config(dir, [a_src, b_src], [a_test, b_test], cache: "cache") }
      run_and_capture_map(config.call)
      clear_markers(dir)
      _aggregate, maps, err = run_and_capture_map(config.call, track_hits: true)
      assert_equal [true], maps.last.instance_variable_get(:@hits)
      assert_includes err, "running 1 of 2 test files"
      refute_path_exists marker(dir, "b")
    end
  end

  # Devin on #557: a narrowed run can reuse part of a full-run cache through
  # partial recapture (#421), when the dropped tests pair with no source by
  # convention. The reused map must equal a capture of the narrowed list: the
  # dropped test leaves every entry and never runs.
  def test_a_narrowed_run_can_partly_reuse_a_full_run_cache
    with_repo do |dir, a_src, b_src, a_test, b_test|
      run_and_capture_map(run_config(dir, [a_src, b_src], [a_test, b_test], paired: false))
      clear_markers(dir)
      plans = []
      real_new = Mutineer::CoverageMap.method(:new)
      map = nil
      _out, err = capture_subprocess_io do
        Mutineer::CoverageMap.stub(:new, lambda { |**kwargs|
          map = real_new.call(**kwargs)
          map.define_singleton_method(:partial_plan) { |cached| super(cached).tap { |plan| plans << plan } }
          map
        }) do
          Mutineer::Runner.execute(run_config(dir, [a_src, b_src], [a_test, b_test]))
        end
      end
      assert_includes err, "running 1 of 2 test files"
      assert_equal [["b_test.rb"]], plans.map { |plan| plan && plan["removed"] }, "partial reuse drops the omitted test"
      refute_path_exists marker(dir, "b")
      map.instance_variable_get(:@map).each_value { |tests| refute_includes tests, "b_test.rb" }
      line = File.read(a_src).lines.index { |l| l.include?("# touched") } + 1
      assert_equal ["a_test.rb"], map.tests_for(a_src, line)
    end
  end

  # AE2: the setting off keeps 1.9.0: both tests load and no line prints.
  def test_without_the_setting_every_test_is_captured
    with_repo do |dir, a_src, b_src, a_test, b_test|
      config = run_config(dir, [a_src, b_src], [a_test, b_test], paired: false)
      _aggregate, _maps, err = run_and_capture_map(config)
      assert_path_exists marker(dir, "a")
      assert_path_exists marker(dir, "b")
      refute_includes err, "--since: running"
    end
  end

  # AE6: no mutant on a changed line returns before the map, as in #396, and
  # prints no narrowing line.
  def test_an_empty_scope_still_returns_before_the_map
    with_repo do |dir, a_src, b_src, a_test, b_test|
      File.write(a_src, File.read(a_src).sub(" # touched", ""))
      File.write(a_src, File.read(a_src).sub("class ScopeA\n", "class ScopeA\n  # note\n"))
      config = run_config(dir, [a_src, b_src], [a_test, b_test])
      aggregate = nil
      _out, err = capture_io do
        Mutineer::CoverageMap.stub(:new, ->(**) { flunk "built the coverage map (#396)" }) do
          aggregate, = Mutineer::Runner.execute(config)
        end
      end
      assert_equal 0, aggregate.total
      refute_includes err, "--since: running"
    end
  end

  private

  def scope_config(**overrides)
    Mutineer::Config.new(**{ sources: ROWS.keys, tests: ALL_TESTS.dup, tests_by_source: ROWS.dup,
                             project_root: ROOT, since: "HEAD", since_paired_tests: true }.merge(overrides))
  end

  def with_repo
    Dir.mktmpdir("mutineer-since-scope") do |dir|
      a_src = File.join(dir, "a.rb")
      b_src = File.join(dir, "b.rb")
      a_test = File.join(dir, "a_test.rb")
      b_test = File.join(dir, "b_test.rb")
      File.write(a_src, "class ScopeA\n  def add(x, y)\n    x + y\n  end\nend\n")
      File.write(b_src, "class ScopeB\n  def add(x, y)\n    x + y\n  end\nend\n")
      File.write(a_test, test_body(dir, "a", "ScopeA"))
      File.write(b_test, test_body(dir, "b", "ScopeB"))
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "t@t")
      git(dir, "config", "user.name", "t")
      git(dir, "add", ".")
      git(dir, "commit", "-qm", "base")
      File.write(a_src, File.read(a_src).sub("x + y", "x + y # touched"))
      yield dir, a_src, b_src, a_test, b_test
    end
  end

  def test_body(dir, name, klass)
    <<~RUBY
      File.write(#{marker(dir, name).dump}, "loaded\\n", mode: "a")
      require "minitest/autorun"
      require_relative #{name.dump} unless defined?(#{klass})
      class #{klass}Test < Minitest::Test
        def test_add
          assert_equal 5, #{klass}.new.add(2, 3)
        end
      end
    RUBY
  end

  def marker(dir, name) = File.join(dir, "#{name}_loaded.txt")

  def clear_markers(dir)
    %w[a b].each { |n| FileUtils.rm_f(marker(dir, n)) }
  end

  def git(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  # Runs the config and returns the result, every CoverageMap the run built,
  # and stderr. With `track_hits`, each map records the answer of `cache_hit?`.
  def run_and_capture_map(config, track_hits: false)
    maps = []
    real_new = Mutineer::CoverageMap.method(:new)
    aggregate = nil
    _out, err = capture_subprocess_io do
      Mutineer::CoverageMap.stub(:new, lambda { |**kwargs|
        map = real_new.call(**kwargs)
        if track_hits
          hits = map.instance_variable_set(:@hits, [])
          map.define_singleton_method(:cache_hit?) { |cached| super(cached).tap { |hit| hits << hit } }
        end
        maps << map
        map
      }) do
        aggregate, = Mutineer::Runner.execute(config)
      end
    end
    [aggregate, maps, err]
  end

  def run_config(dir, sources, tests, strategy: "reload", boot: nil, cache: "cache", paired: true)
    rows = sources.zip(tests).to_h { |src, test| [src, [test]] }
    Mutineer::Config.new(
      sources: sources, tests: tests, tests_by_source: rows, project_root: dir, since: "HEAD",
      since_paired_tests: paired, operators: OPS, strategy: strategy, boot: boot, jobs: 1,
      cache_dir: File.join(dir, cache), framework: "minitest"
    )
  end
end
