# frozen_string_literal: true

# #512: a superclass expression that sets a local a later line reads. Each
# `Struct.new` builds a new class, so a second load must keep the live one.
class Quad < (base = Struct.new(:a))
  def four? = a == 4
end
QUAD_BASE = base

class Plain < base = Struct.new(:b)
  def five? = b == 5
end
PLAIN_BASE = base
