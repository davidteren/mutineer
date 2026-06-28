# frozen_string_literal: true

require "minitest/autorun"
require_relative "namespaced"

# total(5, 2) == (5 * 2) * RATE == 10. This suite pins only that one value, so:
#   - base = price * qty  (*->/) : 5/2*1 = 2  != 10  -> killed
#   - statement_removal of `base = ...` : base undefined -> error in test -> killed
#   - base * RATE         (*->/) : 10/1 = 10  == 10  -> SURVIVES  (the oracle)
class ShopOrderTest < Minitest::Test
  def test_total
    assert_equal 10, Shop::Order.new.total(5, 2)
  end
end
