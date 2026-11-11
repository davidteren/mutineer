# frozen_string_literal: true

require "test_helper"

class ShipmentTest < ActiveSupport::TestCase
  test "heavy above one kilogram" do
    assert Shipment.new(weight_grams: 1_001).heavy?
    refute Shipment.new(weight_grams: 1_000).heavy?
  end

  test "saves without a weight because it skips the parent callback" do
    assert Shipment.new(weight_grams: 0).save
  end

  test "keeps its enum" do
    assert Shipment.new(status: :shipped).shipped?
  end
end
