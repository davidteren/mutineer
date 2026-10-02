# frozen_string_literal: true

require "minitest/autorun"
require_relative "continuation"

class ContinuationTest < Minitest::Test
  def test_summary
    assert_equal({ yes: 2, no: 1 }, Continuation.summary({ true => 2, false => 1 }))
  end

  def test_message
    assert_equal "true\n", Continuation.message(3)
  end
end
