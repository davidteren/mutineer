# frozen_string_literal: true

require "minitest/autorun"
require_relative "steps"

# Deliberately never checks the last step: tests the first step only. So the
# `..` -> `...` mutation survives undetected — nothing checks that n is included.
class StepsTest < Minitest::Test
  def test_upto_starts_at_one
    assert_equal 1, Steps.new.upto(3).first
  end
end
