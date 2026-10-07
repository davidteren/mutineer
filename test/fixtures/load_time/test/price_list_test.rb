# frozen_string_literal: true

require "minitest/autorun"
require_relative "../setup/price_table"

class PriceListTest < Minitest::Test
  def test_price_table
    assert_equal [6], PRICE_TABLE
  end
end
