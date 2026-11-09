# frozen_string_literal: true

# Reloading this file runs its class body again: the `enum` (#378) and the
# `skip_callback` (#384) would each raise on the second run.
class Shipment < ShippingRecord
  include Trackable

  enum :status, { pending: 0, shipped: 1 }
  skip_callback :save, :before, :require_weight

  def heavy?
    weight_grams > 1_000
  end
end
