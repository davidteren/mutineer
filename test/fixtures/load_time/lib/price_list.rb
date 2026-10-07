# frozen_string_literal: true

# #217: nothing here runs at load. The `--require` file setup/price_table.rb
# calls `price` while it loads, to build PRICE_TABLE.
class PriceList
  def self.price(base)
    base * 2
  end
end
