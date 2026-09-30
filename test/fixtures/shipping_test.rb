# frozen_string_literal: true

require "minitest/autorun"
require_relative "shipping"

# Deliberately tests a small order only. So forcing the condition to `false`
# survives undetected — nothing checks that a large order ships free.
class ShippingTest < Minitest::Test
  def test_small_order_pays_the_fee
    assert_equal 5, Shipping.new.fee(20)
  end
end
