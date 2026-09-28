# frozen_string_literal: true

require "minitest/autorun"
require_relative "discount"

# Deliberately checks only large totals. So keeping `member` alone survives
# undetected — nothing checks that a member with a small total is refused.
class DiscountTest < Minitest::Test
  def test_member_with_large_total_is_eligible
    assert Discount.new.eligible?(true, 150)
  end

  def test_guest_with_large_total_is_not_eligible
    refute Discount.new.eligible?(false, 150)
  end
end
