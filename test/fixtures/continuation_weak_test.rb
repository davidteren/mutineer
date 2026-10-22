# frozen_string_literal: true

require "minitest/autorun"
require_relative "continuation"

# Runs `adult?` only with verified false, so `age > 17` never runs.
class ContinuationWeakTest < Minitest::Test
  def test_unverified
    refute Continuation.adult?(18, false)
  end
end
