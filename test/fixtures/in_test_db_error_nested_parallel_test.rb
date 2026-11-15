# frozen_string_literal: true

require "minitest/autorun"
require "minitest/parallel"
require "stringio"

# Stand-in for the connection error (#347). Loaded only in a forked child.
module ActiveRecord
  class ConnectionNotEstablished < StandardError; end
end

# Two workers, so parallelize_me! queues instead of running in this thread.
Minitest.parallel_executor = Minitest::Parallel::Executor.new(2)

# Outer queue order is test_a_first, then test_b_second. test_a fails an
# assertion. test_b raises a connection error. The serial class below queues
# those methods on its own reporter in the opposite order. That nested order
# must not decide the run (review of #453).
class InTestDatabaseErrorNestedOrder < Minitest::Test
  parallelize_me!

  # The order the outer run enqueues, independent of the seed's shuffle.
  #
  # @return [Array<String>]
  def self.runnable_methods
    %w[test_a_first test_b_second]
  end

  def test_a_first
    flunk "an assertion fails"
  end

  def test_b_second
    raise ActiveRecord::ConnectionNotEstablished, "the database is gone"
  end
end

class InTestDatabaseErrorNestedSerial < Minitest::Test
  def test_queues_the_parallel_class_backwards
    reporter = Minitest::CompositeReporter.new(Minitest::SummaryReporter.new(StringIO.new))
    reporter.start
    klass = InTestDatabaseErrorNestedOrder
    # The opposite of the outer runnable_methods order, on a reporter that is
    # not the run's.
    Minitest.parallel_executor << [klass, "test_b_second", reporter]
    Minitest.parallel_executor << [klass, "test_a_first", reporter]
    pass
  end
end
