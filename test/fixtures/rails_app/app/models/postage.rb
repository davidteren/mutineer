# frozen_string_literal: true

# A parent whose callback one subclass skips and another skips only for
# express parcels (#414). With eager loading on, a reload of this file runs
# `before_save` again, and Rails appends it to both loaded subclasses.
class Postage < ApplicationRecord
  self.abstract_class = true

  before_save :require_weight

  def heavy?
    weight_grams > 1_000 && weight_grams < 30_000
  end

  private

  def require_weight
    throw :abort unless weight_grams > 0
  end
end
