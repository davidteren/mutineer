# frozen_string_literal: true

require "minitest/autorun"
require_relative "concern_included"

class ConcernIncludedTest < Minitest::Test
  def test_tag
    assert_equal "long", ConcernPost.new.tag("abcd")
    assert_equal "short", ConcernPost.new.tag("abc")
  end
end
