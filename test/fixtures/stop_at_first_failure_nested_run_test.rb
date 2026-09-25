# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

# A test drives the suite runner with its own reporter and an inner class
# that fails on purpose, as a plugin gem can do.
class StopAtFirstFailureNestedRunFixture < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def test_a_runs_an_inner_suite_that_fails
    inner = Class.new(Minitest::Test) do
      def self.name = "StopAtFirstFailureInnerFixture"
      def test_fails = flunk("an expected inner failure")
    end
    saved = Minitest::Runnable.runnables.dup
    Minitest::Runnable.runnables.replace([inner])
    reporter = Minitest::CompositeReporter.new(Minitest::SummaryReporter.new(StringIO.new))
    reporter.start
    begin
      if Minitest.respond_to?(:run_all_suites)
        Minitest.run_all_suites(reporter, {})
      else
        Minitest.__run(reporter, {})
      end
    ensure
      Minitest::Runnable.runnables.replace(saved - [inner])
    end
    reporter.report
    refute_predicate reporter, :passed?
  end

  def test_b_writes_marker
    File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), "ran")
    pass
  end
end
