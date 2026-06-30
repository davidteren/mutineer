# frozen_string_literal: true

require "test_helper"

# STRONG suite: pins every branch and boundary, so Mutineer's default Tier-1
# operators should leave NO survivors on covered lines (mutation score 100%).
# The boundary fixtures (`edge`, `bulk_rush`) exist specifically to kill the
# > vs >= and && vs || mutants that a coverage-only suite would miss.
class OrderTest < ActiveSupport::TestCase
  def test_subtotal_is_quantity_times_unit_price
    assert_equal 2000, orders(:small).subtotal_cents
    assert_equal 50_000, orders(:bulk).subtotal_cents
  end

  def test_total_below_threshold_is_unchanged
    assert_equal 2000, orders(:small).total_cents
  end

  def test_total_at_threshold_gets_no_discount
    # Exactly 10000 is NOT > 10000 — kills the `>`->`>=` boundary mutant.
    assert_equal 10_000, orders(:edge).total_cents
  end

  def test_total_above_threshold_gets_bulk_discount
    assert_equal 45_000, orders(:bulk).total_cents
  end

  def test_rush_adds_surcharge
    assert_equal 2500, orders(:rush_small).total_cents
  end

  def test_bulk_and_rush_compose
    assert_equal 45_500, orders(:bulk_rush).total_cents
  end

  def test_free_shipping_requires_threshold_met_and_not_rush
    assert orders(:bulk).free_shipping?, "bulk, non-rush qualifies"
    # Exactly 10000 with >= qualifies — kills the `>=`->`>` boundary mutant.
    assert orders(:edge).free_shipping?, "at threshold qualifies"
    refute orders(:small).free_shipping?, "below threshold does not"
    refute orders(:rush_small).free_shipping?, "rush disqualifies"
    # subtotal qualifies but rush disqualifies — kills the `&&`->`||` mutant.
    refute orders(:bulk_rush).free_shipping?, "bulk + rush does not qualify"
  end
end
