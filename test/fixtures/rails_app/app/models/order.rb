# frozen_string_literal: true

# The mutation target. Pure, deterministic business logic (no I/O) so every
# mutant's fate is decided purely by the test assertions — ideal for dogfooding.
class Order < ApplicationRecord
  BULK_THRESHOLD_CENTS = 10_000
  RUSH_SURCHARGE_CENTS = 500

  def subtotal_cents
    quantity * unit_price_cents
  end

  # Bulk orders get 10% off; a rush order adds a flat surcharge. Multiple
  # statements + arithmetic + a comparison + a boolean literal gate, so the
  # default Tier-1 operators all have something to mutate here.
  def total_cents
    cents = subtotal_cents
    cents = (cents * 0.9).round if cents > BULK_THRESHOLD_CENTS
    cents += RUSH_SURCHARGE_CENTS if rush
    cents
  end

  def free_shipping?
    subtotal_cents >= BULK_THRESHOLD_CENTS && !rush
  end
end
