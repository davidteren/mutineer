# frozen_string_literal: true

# A concern with an `included` block. The fixture app loads lazily
# (`eager_load = false`), so a mutant of this file is the first thing to
# reference `Trackable` in its fork (#383).
module Trackable
  extend ActiveSupport::Concern

  included do
    scope :express_only, -> { where(express: true) }
    before_save :require_tracking
  end

  def light?
    weight_grams < 100
  end

  private

  # Shipment skips this callback, which this block installed on Shipment
  # itself. A reload does not run the block again (#384 review).
  def require_tracking
    throw :abort
  end
end
