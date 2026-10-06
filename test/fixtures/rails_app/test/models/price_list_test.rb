# frozen_string_literal: true

require "test_helper"

class PriceListTest < ActiveSupport::TestCase
  def test_all
    assert_equal [6], PriceList::ALL
  end

  def test_discount
    assert_equal 5, PriceList.discount(6)
  end
end
