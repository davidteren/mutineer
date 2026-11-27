# frozen_string_literal: true

# #533, its first example: reload keeps `LiteralFields` (#528), so `LiteralRow`
# has the right parent and `total` gets a real verdict.
LiteralFields = Struct.new(:v) do
  def total = v + 1
end

class LiteralRow < Class.new(LiteralFields)
  def three? = v == 3

  def weak? = v == 4
end
