# frozen_string_literal: true

require "minitest/autorun"
require_relative "continuation_reach"

# Runs each continuation and checks a result that `>` to `>=` and `+` to `-`
# still satisfy. `adult?` never sees age 17. `sums` subtracts a smaller
# number, so the difference stays positive.
class ContinuationReachTest < Minitest::Test
  def test_adult
    assert ContinuationReach.adult?(20, true)
    refute ContinuationReach.adult?(10, true)
  end

  def test_labels
    long = Object.new
    def long.name = "ab"
    short = Object.new
    def short.name = ""

    assert_equal [true, false], ContinuationReach.labels([long, short])
  end

  def test_widths
    assert_equal %w[true false], ContinuationReach.widths(["ab", ""])
  end

  def test_tally
    assert_equal({ n: 3, wide: true }, ContinuationReach.tally(true, 3))
    assert_equal({ n: 0, wide: false }, ContinuationReach.tally(true, 0))
  end

  def test_note
    assert_equal "true\n", ContinuationReach.note(true, 3)
    assert_equal "false\n", ContinuationReach.note(true, 0)
  end

  def test_sums
    assert_operator ContinuationReach.sums(true, 5, 1), :>, 0
  end
end
