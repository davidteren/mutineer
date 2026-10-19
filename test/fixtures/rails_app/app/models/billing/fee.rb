# frozen_string_literal: true

# A model in a namespace directory. Zeitwerk scans app/models/billing/ only
# when code first reopens Billing, so a mutant file written there must stay
# hidden from it, also when parallel workers write theirs at once (#253).
module Billing
  class Fee
    def self.for(amount)
      amount > 100 ? 5 : 0
    end

    def self.waived?(amount)
      amount < 10
    end

    def self.discount(amount)
      amount >= 500 ? 50 : 0
    end
  end
end
