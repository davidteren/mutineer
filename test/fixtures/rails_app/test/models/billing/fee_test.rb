# frozen_string_literal: true

require_relative "../../test_helper"

class Billing::FeeTest < ActiveSupport::TestCase
  test "charges a fee above 100" do
    assert_equal 5, Billing::Fee.for(101)
    assert_equal 0, Billing::Fee.for(100)
  end

  test "waives a fee below 10" do
    assert Billing::Fee.waived?(9)
    refute Billing::Fee.waived?(10)
  end

  test "discounts from 500" do
    assert_equal 50, Billing::Fee.discount(500)
    assert_equal 0, Billing::Fee.discount(499)
  end
end
