# frozen_string_literal: true

require "minitest/autorun"

# A failing serial test and a passing parallel class. Minitest runs the serial
# class first, so the recorder's `kill` line comes before its `parallel` line.
class MatrixSerialFails < Minitest::Test
  def test_fails
    flunk "kill"
  end
end

class MatrixParallelPasses < Minitest::Test
  parallelize_me!

  def test_passes
    assert true
  end
end
