# frozen_string_literal: true

# #376: the gem entry file. It loads price, then cart, so Cart can read Price::TAX.
require_relative "shop/price"
require_relative "shop/cart"
