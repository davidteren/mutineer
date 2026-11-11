# frozen_string_literal: true

# Plain class with no conventional paired test. The integration test is the
# only killer; the tests: map names it for daemon coverage (#382).
class ShippingQuote
  def self.fee_cents(weight)
    weight + 100
  end
end
