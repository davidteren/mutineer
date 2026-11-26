# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# #187: a method the class body (or the app boot) calls runs before the mutant
# is applied. Redefine never re-runs that load, so a test that checks the value
# it built saw the original code: a false survivor. In boot mode no test was
# credited with those lines: a false no_coverage. Both are now `ran_at_load`,
# excluded from the score; a kill stays a kill.
#
# Each run is a fresh process: boot mode starts Coverage and requires the boot
# file once, and both only work in a process that has not loaded the fixture.
class LoadTimeTest < Minitest::Test
  ROOT = File.expand_path("fixtures/load_time", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  # Runs Runner.execute in a child ruby and returns [[subject, status], ...],
  # the score, and the subjects of the ran_at_load results that survived their
  # tests before a load rule moved them (#286).
  def run_load_time(source, test, strategy:, boot: nil, requires: [], framework: "minitest")
    Dir.mktmpdir("mutineer-load-time") do |cache|
      script = <<~RUBY
        require "mutineer"
        require "json"
        config = Mutineer::Config.new(sources: [#{source.inspect}], tests: [#{test.inspect}],
                                      boot: #{boot.inspect}, strategy: #{strategy.inspect},
                                      require_paths: #{requires.inspect}, framework: #{framework.inspect},
                                      project_root: #{ROOT.inspect}, cache_dir: #{cache.inspect}, jobs: 1)
        agg = Mutineer::Runner.execute(config).first
        # R13 (#286): a ran_at_load result is tested exactly when it has a run
        # time. This catches a load rule that moves a survivor and forgets the
        # mark. If a later change gives a run time to a result that never ran,
        # change this check, not the field.
        agg.results.select(&:ran_at_load?).each do |r|
          raise "tested_at_load and seconds disagree: \#{r.subject.qualified_name}" unless r.tested_at_load? == !r.seconds.nil?
        end
        $stdout.puts JSON.generate("results" => agg.results.map { |r| [r.subject.qualified_name, r.status] },
                                   "score" => agg.mutation_score,
                                   "tested" => agg.results.select(&:tested_at_load?).map { |r| r.subject.qualified_name })
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script, chdir: ROOT)
      assert status.success?, "run failed: #{err}"
      doc = JSON.parse(out.lines.last)
      [doc["results"], doc["score"], doc["tested"]]
    end
  end

  def catalog(strategy:, boot: nil)
    run_load_time("lib/catalog.rb", "test/catalog_test.rb", strategy: strategy, boot: boot)
  end

  def test_standalone_reload_still_kills_the_load_time_mutant
    results, score = catalog(strategy: "reload")
    assert_equal [["Catalog.price", "killed"]], results
    assert_equal 100.0, score
  end

  def test_standalone_redefine_reports_ran_at_load_not_survived
    results, score, tested = catalog(strategy: "redefine")
    assert_equal [["Catalog.price", "ran_at_load"]], results
    assert_nil score
    # AE1 (#286): it survived its test first, so it can hide a test gap.
    assert_equal ["Catalog.price"], tested
  end

  def test_boot_reports_ran_at_load_not_no_coverage
    %w[reload redefine].each do |strategy|
      results, score, tested = catalog(strategy: strategy, boot: "boot.rb")
      assert_equal [["Catalog.price", "ran_at_load"]], results, strategy
      assert_nil score, strategy
      # AE2 (#286): no test covers the line in boot mode, so the mutant never ran.
      assert_empty tested, strategy
    end
  end

  # A lazily loaded class (Zeitwerk, autoload) must load in the parent, before
  # the boot coverage is read. Otherwise the redefine child loads it with the
  # original method, and the mutant falsely survives.
  def test_boot_redefine_preloads_a_lazily_loaded_class
    results, = catalog(strategy: "redefine", boot: "autoload_boot.rb")
    assert_equal [["Catalog.price", "ran_at_load"]], results
  end

  # A Class.new block owner has no lexical namespace, so the preload must
  # resolve the owner itself.
  def test_boot_redefine_preloads_a_lazily_loaded_builder_class
    results, = run_load_time("lib/builder_catalog.rb", "test/builder_catalog_test.rb",
                             strategy: "redefine", boot: "autoload_builder_boot.rb")
    assert_equal [["BuilderCatalog.price", "ran_at_load"]], results
  end

  # #217: a `--require` file runs in the parent before the mutants fork, so
  # the standalone capture must load it too, before it reads the load
  # coverage. Otherwise `price` is missed and the mutant falsely survives.
  def test_standalone_require_file_that_calls_a_source_at_load_reports_ran_at_load
    [%w[minitest test/price_list_test.rb], %w[rspec spec/price_list_spec.rb]].each do |framework, test|
      %w[reload redefine].each do |strategy|
        results, score = run_load_time("lib/price_list.rb", test, strategy: strategy,
                                                                  requires: ["setup/price_table"], framework: framework)
        assert_equal [["PriceList.price", "ran_at_load"]], results, "#{framework} #{strategy}"
        assert_nil score, "#{framework} #{strategy}"
      end
    end
  end

  # #209: a one-line or endless def called at load is ran_at_load (by its
  # method call count), and one that only the tests call keeps its verdict.
  def test_survivors_and_kills_that_do_not_depend_on_load_keep_their_verdict
    results, _score, tested = run_load_time("lib/shelf.rb", "test/shelf_test.rb", strategy: "redefine")
    assert_equal %w[Shelf.bump Shelf.short], tested.sort # #286: both survived their tests first
    assert_equal({ "Shelf.double" => %w[killed], # ran at load, but the test kills it
                   "Shelf.tax" => %w[survived], # runs at test time only
                   "Shelf.bump" => %w[ran_at_load], # one-line def called at load
                   "Shelf.short" => %w[ran_at_load], # endless def called at load
                   "Shelf.half" => %w[killed], # endless def, test time only
                   "Shelf.ping" => %w[survived] }, # one-line def, test time only
                 statuses_by_subject(results))
  end

  # #209: under --boot the forked tests do not repeat the load, so a one-line
  # or endless def called only at load was a false no_coverage.
  def test_boot_reports_one_line_defs_called_at_load_as_ran_at_load
    %w[reload redefine].each do |strategy|
      results, _score, tested = run_load_time("lib/shelf.rb", "test/shelf_test.rb", strategy: strategy,
                                                                                     boot: "shelf_boot.rb")
      # #286: no test is selected for bump and short in boot mode, so they never ran.
      assert_empty tested, strategy
      statuses = statuses_by_subject(results)
      assert_equal %w[ran_at_load], statuses["Shelf.bump"], strategy
      assert_equal %w[ran_at_load], statuses["Shelf.short"], strategy
      assert_equal %w[killed], statuses["Shelf.half"], strategy
      assert_equal %w[survived], statuses["Shelf.ping"], strategy
    end
  end

  # AE5, AE6 (#286): ran_at_load mutants join the unrun-share warning, which
  # names the tested part, and the exit code and score do not change.
  def test_cli_warns_on_the_ran_at_load_share_and_keeps_the_exit_code
    Dir.mktmpdir("mutineer-load-time-cli") do |cache|
      env = ENV.to_h.merge("CI" => nil)
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I#{LIB}", File.expand_path("../bin/mutineer", __dir__),
                                        "run", "lib/shelf.rb", "--test", "test/shelf_test.rb", "--strategy", "redefine",
                                        "--format", "json", "--threshold", "50", "--cache-dir", cache, chdir: ROOT)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "[mutineer] 2 of the 6 mutants mutineer tried to score were not run or were classed as " \
                           "ran at load (2 ran at load of which 2 survived their tests; 33.3%, limit 10%)."
      summary = JSON.parse(out)["summary"]
      assert_equal [2, 2, 50.0], summary.values_at("ran_at_load", "ran_at_load_tested", "score")
    end
  end

  def statuses_by_subject(results)
    results.group_by(&:first).transform_values { |rows| rows.map(&:last).uniq.sort }
  end
end
