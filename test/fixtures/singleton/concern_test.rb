# frozen_string_literal: true

require "minitest/autorun"
require_relative "concern"

class ConcernTest < Minitest::Test
  def test_greet
    assert_equal "Hello, Ada", ConcernGreeter.greet("Ada")
    assert_nil ConcernGreeter.greet(nil)
    assert_nil ConcernGreeter.greet("")
  end
end
