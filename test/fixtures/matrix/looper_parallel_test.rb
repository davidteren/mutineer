# frozen_string_literal: true

require "minitest/autorun"
require_relative "looper"

# parallelize_me! queues both tests before either finishes, so the stop at the
# first failure cannot keep test_b_count from looping under `i - 1`.
class MatrixLooperParallelTest < Minitest::Test
  parallelize_me!

  def test_a_next
    assert_equal 3, MatrixLooper.next_i(2)
  end

  def test_b_count
    assert_equal 5, MatrixLooper.count_to(5)
  end
end
