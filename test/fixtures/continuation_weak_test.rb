# frozen_string_literal: true

require "minitest/autorun"
require_relative "continuation"

# Runs `adult?` only with verified false, so `age > 17` never runs. Runs
# `names` only with no users, so the block never runs.
class ContinuationWeakTest < Minitest::Test
  def test_unverified
    refute Continuation.adult?(18, false)
  end

  def test_names_with_no_users
    assert_equal [], Continuation.names([])
  end
end
