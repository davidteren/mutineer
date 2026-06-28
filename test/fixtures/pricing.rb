# frozen_string_literal: true

class Pricing
  def total(price)
    if price >= 100
      price * 0.9
    else
      price
    end
  end
end
