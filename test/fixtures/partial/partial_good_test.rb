# frozen_string_literal: true

require "minitest/autorun"
require_relative "partial"

# Basename maps to "partial_good" (NOT "partial"), so it is not a failed target;
# it just supplies real coverage for #covered.
class PartialGoodTest < Minitest::Test
  def test_covered
    assert_equal 5, Partial.new.covered(2, 3)
  end
end
