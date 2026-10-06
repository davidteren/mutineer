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

  # Runs Runner.execute in a child ruby and returns [[subject, status], ...]
  # plus the score.
  def run_load_time(source, test, strategy:, boot: nil)
    Dir.mktmpdir("mutineer-load-time") do |cache|
      script = <<~RUBY
        require "mutineer"
        require "json"
        config = Mutineer::Config.new(sources: [#{source.inspect}], tests: [#{test.inspect}],
                                      boot: #{boot.inspect}, strategy: #{strategy.inspect},
                                      project_root: #{ROOT.inspect}, cache_dir: #{cache.inspect}, jobs: 1)
        agg = Mutineer::Runner.execute(config).first
        $stdout.puts JSON.generate("results" => agg.results.map { |r| [r.subject.qualified_name, r.status] },
                                   "score" => agg.mutation_score)
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script, chdir: ROOT)
      assert status.success?, "run failed: #{err}"
      doc = JSON.parse(out.lines.last)
      [doc["results"], doc["score"]]
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
    results, score = catalog(strategy: "redefine")
    assert_equal [["Catalog.price", "ran_at_load"]], results
    assert_nil score
  end

  def test_boot_reports_ran_at_load_not_no_coverage
    %w[reload redefine].each do |strategy|
      results, score = catalog(strategy: strategy, boot: "boot.rb")
      assert_equal [["Catalog.price", "ran_at_load"]], results, strategy
      assert_nil score, strategy
    end
  end

  # A lazily loaded class (Zeitwerk, autoload) must load in the parent, before
  # the boot coverage is read. Otherwise the redefine child loads it with the
  # original method, and the mutant falsely survives.
  def test_boot_redefine_preloads_a_lazily_loaded_class
    results, = catalog(strategy: "redefine", boot: "autoload_boot.rb")
    assert_equal [["Catalog.price", "ran_at_load"]], results
  end

  def test_survivors_and_kills_that_do_not_depend_on_load_keep_their_verdict
    results, = run_load_time("lib/shelf.rb", "test/shelf_test.rb", strategy: "redefine")
    assert_equal({ "Shelf.double" => "killed", # ran at load, but the test kills it
                   "Shelf.tax" => "survived", # runs at test time only
                   "Shelf.bump" => "survived", # known limit: one-line def
                   "Shelf.short" => "survived" }, # known limit: endless def
                 results.to_h)
  end
end
