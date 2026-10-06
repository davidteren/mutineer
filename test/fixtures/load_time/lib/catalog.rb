# frozen_string_literal: true

# #187: `price` runs while the class body loads, to build ALL. The test checks
# ALL, a value computed before any mutant is applied.
class Catalog
  def self.price(base)
    base * 2
  end

  ALL = [price(3)].freeze
end
