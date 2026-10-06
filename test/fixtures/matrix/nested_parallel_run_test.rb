# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

# A serial test runs an already-loaded parallel class on its own reporter, then
# a later serial test fails. The nested run is not the run's parallel phase, so
# the failure must still count as a serial kill (#191).
class MatrixNestedParallelRunFixture < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def test_a_runs_a_parallel_class_on_its_own_reporter
    reporter = Minitest::CompositeReporter.new(Minitest::SummaryReporter.new(StringIO.new))
    reporter.start
    klass = MatrixNestedParallelClassFixture
    Minitest::Runnable.respond_to?(:run_suite) ? klass.run_suite(reporter, {}) : klass.run(reporter, {})
    pass
  end

  def test_b_fails
    flunk "a serial failure"
  end
end

class MatrixNestedParallelClassFixture < Minitest::Test
  parallelize_me!

  def test_passes = pass
end
