# frozen_string_literal: true

# A parent that defines a callback a subclass skips (#384).
class ShippingRecord < ApplicationRecord
  self.abstract_class = true

  before_save :require_weight

  private

  def require_weight
    throw :abort unless weight_grams.positive?
  end
end
