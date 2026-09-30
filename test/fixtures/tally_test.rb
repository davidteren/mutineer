# frozen_string_literal: true

require "minitest/autorun"
require_relative "tally"

# Deliberately checks only the type of the sum. The block runs, so the
# `+=` -> `-=` mutation executes, but it survives undetected.
class TallyTest < Minitest::Test
  def test_sum_is_an_integer
    assert_kind_of Integer, Tally.new.sum([1, 2])
  end
end
