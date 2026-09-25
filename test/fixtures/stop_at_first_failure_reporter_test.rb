# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

# A test records a failing result on its own CompositeReporter, as a gem
# that tests its reporters does.
class StopAtFirstFailureReporterFixture < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def test_a_records_a_failure_on_an_own_reporter
    counter = Minitest::StatisticsReporter.new(StringIO.new)
    composite = Minitest::CompositeReporter.new(counter)
    composite.start
    failing = Minitest::Result.new("inner")
    failing.failures = [Minitest::Assertion.new("an expected failure")]
    composite.record(failing)
    assert_equal 1, counter.count
    refute_predicate counter, :passed?
  end

  def test_b_writes_marker
    File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), "ran")
    pass
  end
end
