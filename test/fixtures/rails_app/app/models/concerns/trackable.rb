# frozen_string_literal: true

# A concern with an `included` block. The fixture app loads lazily
# (`eager_load = false`), so a mutant of this file is the first thing to
# reference `Trackable` in its fork (#383).
module Trackable
  extend ActiveSupport::Concern

  included do
    scope :express_only, -> { where(express: true) }
  end

  def light?
    weight_grams < 100
  end
end
