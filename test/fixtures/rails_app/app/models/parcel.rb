# frozen_string_literal: true

# Reload runs this class body again. Rails keeps one copy of a callback that
# names a method, but appends a second copy of each validator and each block
# callback (#390). ParcelTest counts errors and callback runs, so without
# Mutineer::ReloadGuards::RepeatedCallbacks every mutant of `heavy?` would be
# a false kill under reload.
class Parcel < ApplicationRecord
  self.table_name = "shipments"

  attr_accessor :checks

  validates :weight_grams, numericality: { greater_than: 0 }
  before_validation { self.checks = checks.to_i + 1 }
  validate { errors.add(:express, "needs a weight") if express && weight_grams.zero? }

  def heavy?
    weight_grams > 1_000
  end
end
