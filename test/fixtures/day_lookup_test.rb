# frozen_string_literal: true

require "minitest/autorun"
require_relative "day_lookup"

# Deliberately checks only that a bad day is not a number. The rescue body
# runs, so its `nil` mutant executes, but it survives undetected.
class DayLookupTest < Minitest::Test
  def test_valid_day
    assert_equal 3, DayLookup.new.day("3")
  end

  def test_bad_day_is_not_a_number
    refute_kind_of Integer, DayLookup.new.day("soon")
  end
end
