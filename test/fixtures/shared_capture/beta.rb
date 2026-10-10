# frozen_string_literal: true

require_relative "alpha"

class SharedBeta
  WIDTH = SharedAlpha.widen(3)

  def self.half(x)
    x / 2
  end
end
