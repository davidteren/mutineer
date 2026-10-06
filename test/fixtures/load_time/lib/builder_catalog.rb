# frozen_string_literal: true

# Like catalog.rb, but the class is built by a Class.new block, so its
# subject has a block owner and no lexical namespace.
BuilderCatalog = Class.new do
  def self.price(base)
    base * 2
  end

  const_set(:ALL, [price(3)].freeze)
end
