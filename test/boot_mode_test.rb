# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Proves boot mode end to end WITHOUT Rails/DB: the parent requires a plain boot
# file once (which loads Widget), then each mutant forks, redefines the method,
# and runs the given test files directly — no coverage map involved.
class BootModeTest < Minitest::Test
  BOOT  = File.expand_path("fixtures/boot", __dir__)
  APP   = File.join(BOOT, "app_boot.rb")
  SRC   = File.join(BOOT, "widget.rb")
  STRONG = File.join(BOOT, "widget_strong_test.rb")
  WEAK   = File.join(BOOT, "widget_weak_test.rb")

  def run_boot(test_file, cache_dir:)
    config = Mutineer::Config.new(
      sources: [SRC], tests: [test_file], boot: APP,
      strategy: "redefine", project_root: BOOT, cache_dir: cache_dir, jobs: 1
    )
    Mutineer::Runner.execute(config).first
  end

  def test_strong_suite_kills_every_mutant
    Dir.mktmpdir("mutineer-boot") do |cache|
      agg = run_boot(STRONG, cache_dir: cache)

      assert_operator agg.killed_count, :>, 0, "strong suite should kill mutants"
      assert_empty agg.surviving_mutants, "strong suite should leave no survivors"
      assert_in_delta 100.0, agg.mutation_score, 0.0001

      # Boot mode never builds a coverage map: no cache file, no :no_coverage.
      assert_equal 0, agg.no_coverage_count
      refute_path_exists File.join(cache, "coverage.json"),
                         "boot mode must not write a coverage cache"
    end
  end

  def test_weak_suite_leaves_a_survivor
    Dir.mktmpdir("mutineer-boot") do |cache|
      agg = run_boot(WEAK, cache_dir: cache)

      assert_operator agg.surviving_mutants.size, :>, 0, "weak suite should leave a survivor"
      assert_operator agg.killed_count, :>, 0
      assert_operator agg.mutation_score, :<, 100.0
      assert_equal 0, agg.no_coverage_count
    end
  end

  # The AR reconnect hook is a guarded no-op when ActiveRecord is absent (as here).
  def test_reconnect_active_record_is_noop_without_active_record
    refute defined?(ActiveRecord::Base), "this test assumes AR is not loaded"
    Mutineer::Runner.send(:reconnect_active_record) # must not raise
  end
end
