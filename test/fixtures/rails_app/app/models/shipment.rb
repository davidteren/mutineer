# frozen_string_literal: true

# Reloading this file runs its class body again: the `enum` (#378) and both
# `skip_callback`s (#384) would each raise on the second run. One skips a
# parent's callback, the other one that the Trackable concern installed.
class Shipment < ShippingRecord
  include Trackable

  enum :status, { pending: 0, shipped: 1 }
  skip_callback :save, :before, :require_weight
  skip_callback :save, :before, :require_tracking

  def heavy?
    weight_grams > 1_000
  end
end
