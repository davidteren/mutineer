# frozen_string_literal: true

require "minitest/autorun"
require_relative "continuation_reach"

# Runs the line Ruby counts and never the continuation: a false left side, or
# an empty collection whose block does not run. `sums` is a trailing `+`
# on the right of `&&`.
class ContinuationReachMissTest < Minitest::Test
  def test_unverified
    refute ContinuationReach.adult?(20, false)
  end

  def test_no_labels
    assert_equal [], ContinuationReach.labels([])
  end

  def test_no_widths
    assert_equal [], ContinuationReach.widths([])
  end

  def test_tally_off
    refute ContinuationReach.tally(false, 3)
  end

  def test_note_off
    refute ContinuationReach.note(false, 3)
  end

  def test_sums_off
    refute ContinuationReach.sums(false, 5, 1)
  end
end
