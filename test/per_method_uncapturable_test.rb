# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# #25: uncapturable is tainted per-METHOD, not whole-file. In a file partly
# covered by a good test, a method reachable only by a FAILED capture must be
# :uncapturable — while the covered method's mutants stay real (killed/no_coverage),
# not tainted. Before #25 the whole file had coverage, so the uncovered method's
# mutants were mislabeled :no_coverage.
class PerMethodUncapturableTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_partial
    cfg = Mutineer::Config.new(
      sources: ["test/fixtures/partial/partial.rb"],
      tests: ["test/fixtures/partial/partial_good_test.rb", "test/fixtures/partial/partial_test.rb"],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    agg = nil
    capture_subprocess_io { agg = Mutineer::Runner.execute(cfg).first } # silence the broken-capture stderr
    agg
  end

  def test_uncovered_method_is_uncapturable_covered_method_is_not
    agg = run_partial
    covered   = agg.results.select { |r| r.subject&.name == :covered }
    uncovered = agg.results.select { |r| r.subject&.name == :uncovered }

    refute_empty covered
    refute_empty uncovered

    # #covered got real coverage from the good test -> never uncapturable.
    refute(covered.any?(&:uncapturable?), "covered method must not be tainted uncapturable")

    # #uncovered is reachable only via the failed capture -> uncapturable, and
    # crucially NOT mislabeled as a genuine no_coverage gap (the #25 fix).
    assert(uncovered.any?(&:uncapturable?), "uncovered method should be :uncapturable (#25)")
    refute(uncovered.any?(&:no_coverage?), "uncovered method must not be false :no_coverage")
  end
end
