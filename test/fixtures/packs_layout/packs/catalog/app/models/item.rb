# frozen_string_literal: true

# #494: a Packwerk pack source. Its test lives in the pack, at
# packs/catalog/test/models/item_test.rb.
class Item
  def total(price, qty)
    price * qty
  end
end
