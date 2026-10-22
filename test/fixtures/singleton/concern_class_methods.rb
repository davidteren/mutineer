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

  def halved(x)
    x / 2
  end

  included do
    def doubled(x)
      x * 2
    end
  end
end

module ConcernWrapping
  extend ActiveSupport::Concern

  def tripled(x)
    x * 3
  end

  prepended do
    def decremented(x)
      x - 1
    end
  end
end

class ConcernProduct
  include ConcernPricing
  prepend ConcernWrapping
end
