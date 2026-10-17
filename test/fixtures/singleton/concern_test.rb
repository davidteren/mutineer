# frozen_string_literal: true

require "minitest/autorun"
require_relative "concern"

class ConcernTest < Minitest::Test
  def test_greet
    assert_equal "Hello, Ada", ConcernGreeter.greet("Ada")
    assert_nil ConcernGreeter.greet(nil)
    assert_nil ConcernGreeter.greet("")
  end

  def test_tag
    assert_equal "long", ConcernGreeter.new.tag("abcd")
    assert_equal "short", ConcernGreeter.new.tag("abc")
  end
end
