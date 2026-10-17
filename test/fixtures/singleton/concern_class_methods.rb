# frozen_string_literal: true

require_relative "concern_stub"

module ConcernPricing
  extend ActiveSupport::Concern
  FACTOR = 3

  class_methods do
    def scaled(x)
      x * FACTOR
    end
  end

  included do
    def doubled(x)
      x * 2
    end
  end
end

class ConcernProduct
  include ConcernPricing
end
