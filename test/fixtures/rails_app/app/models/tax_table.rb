# frozen_string_literal: true

# #220: `rate` runs only when the --require file test/support/tax_setup.rb
# loads, so under --daemon it ran at load only if the daemon required that file.
class TaxTable
  def self.rate(cents)
    cents * 2
  end

  # Runs at test time only, and the test kills its mutant.
  def self.round(cents)
    cents + 1
  end
end
