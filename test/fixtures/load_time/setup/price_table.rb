# frozen_string_literal: true

require_relative "../lib/price_list"

# #217: a `--require` file that calls a source method at load.
PRICE_TABLE = [PriceList.price(3)].freeze
