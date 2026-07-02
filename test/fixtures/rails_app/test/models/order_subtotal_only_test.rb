# frozen_string_literal: true

require "test_helper"

# PARTIAL-coverage suite: exercises ONLY subtotal_cents, leaving total_cents and
# free_shipping? uncovered. Used by the daemon coverage test to prove that mutants on
# the uncovered methods come back no_coverage (excluded from score), not survived.
class OrderSubtotalOnlyTest < ActiveSupport::TestCase
  def test_subtotal_is_quantity_times_unit_price
    assert_equal 2000, orders(:small).subtotal_cents
  end
end
