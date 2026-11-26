# frozen_string_literal: true

require "test_helper"

class TrackableTest < ActiveSupport::TestCase
  test "light below 100 grams" do
    assert Shipment.new(weight_grams: 99).light?
    refute Shipment.new(weight_grams: 100).light?
  end
end
