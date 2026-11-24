# frozen_string_literal: true

require "test_helper"

# Weak on purpose: it calls `heavy?` without checking the answer, so its
# mutants survive under every strategy. The counts would kill them only if
# a reload ran a validator or callback twice (#390).
class ParcelTest < ActiveSupport::TestCase
  test "one error and one callback run per check" do
    parcel = Parcel.new(weight_grams: 0, express: true)
    parcel.heavy?

    refute parcel.valid?
    assert_equal 2, parcel.errors.count
    assert_equal 1, parcel.checks
  end
end
