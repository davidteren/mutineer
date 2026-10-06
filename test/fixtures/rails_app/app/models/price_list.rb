# frozen_string_literal: true

# #187: `price` runs while the class body loads, and an initializer loads the
# class at boot, so it runs before any mutant is applied.
class PriceList
  def self.price(base)
    base * 2
  end

  # Runs at test time only, and the test kills its mutant.
  def self.discount(cents)
    cents - 1
  end

  ALL = [price(3)].freeze
end
