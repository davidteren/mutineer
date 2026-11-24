# frozen_string_literal: true

require "test_helper"

class ShippingQuoteFlowTest < ActiveSupport::TestCase
  def test_fee_cents
    assert_equal 150, ShippingQuote.fee_cents(50)
  end
end
