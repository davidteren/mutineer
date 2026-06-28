# frozen_string_literal: true

require "minitest/autorun"
require_relative "pricing"

# Deliberately misses the == 100 boundary: tests 150 (discounted) and 50 (not),
# but never 100 itself. So the `>=` -> `>` mutation survives undetected — the
# boundary-miss survivor that is Brutus's correctness oracle (spec §12).
class PricingTest < Minitest::Test
  def test_discount_above_threshold
    assert_in_delta 135.0, Pricing.new.total(150)
  end

  def test_no_discount_below_threshold
    assert_equal 50, Pricing.new.total(50)
  end
end
