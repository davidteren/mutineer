# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/shop"

class TestCart < Minitest::Test
  def test_total = assert_equal(6, Shop::Cart.total(3))
end
