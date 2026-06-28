# frozen_string_literal: true

require_relative "test_helper"

class ReporterTest < Minitest::Test
  def test_score_excludes_no_coverage_from_denominator
    results = [
      Brutus::Result.killed, Brutus::Result.killed, Brutus::Result.killed,
      Brutus::Result.survived, Brutus::Result.no_coverage, Brutus::Result.no_coverage
    ]
    out = Brutus::Reporter.report(results)
    # 3 killed / (3 killed + 1 survived) = 75%, the 2 no-coverage excluded.
    assert_includes out, "Mutation score: 75.0%"
    assert_includes out, "No coverage: 2"
  end

  def test_no_killable_mutations_reports_na
    out = Brutus::Reporter.report([Brutus::Result.no_coverage])
    assert_includes out, "Mutation score: N/A"
  end
end
