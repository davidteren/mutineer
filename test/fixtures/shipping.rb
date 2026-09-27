# frozen_string_literal: true

class Shipping
  def fee(total)
    total >= 100 ? 0 : 5
  end
end
