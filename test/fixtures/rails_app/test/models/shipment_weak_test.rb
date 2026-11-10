# frozen_string_literal: true

require "test_helper"

# Weak on purpose: it calls `heavy?` and `light?` without checking the
# answers, so every Shipment and Trackable mutant survives. It checks only
# what the reload must keep: the enum (#378), the skipped callbacks (#384)
# and the concern's scope (#383). A guard that broke the class body would
# make the mutant error or be killed, not survive.
class ShipmentWeakTest < ActiveSupport::TestCase
  test "a reloaded class body keeps its enum, skips and scope" do
    shipment = Shipment.new(weight_grams: 0, status: :shipped)
    shipment.heavy?
    shipment.light?

    assert shipment.shipped?
    assert shipment.save
    assert_respond_to Shipment, :express_only
  end
end
