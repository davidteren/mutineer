# frozen_string_literal: true

# #376: the class body reads Price::TAX. This file does not load price.rb.
module Shop
  class Cart
    TAX = Price::TAX

    def self.total(amount) = amount * TAX
  end
end
