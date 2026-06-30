# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/calc"

# Weak on purpose: add(0, 0) leaves +->- and +->* undetected, so this source
# scores below 100% — letting the per-source breakdown show two different scores.
class CalcTest < Minitest::Test
  def test_add
    assert_equal 0, Calc.new.add(0, 0)
  end
end
