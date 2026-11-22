# frozen_string_literal: true

require "delegate"

# #492: other superclass calls (cover the siblings).
class BlockStruct < Struct.new(:a) do
  def in_block? = a == 1
end
  def in_body? = a == 2
end

class Wrapped < DelegateClass(Array)
  def big? = size > 2
end

class Made < Class.new(StandardError)
  def loud? = message == "x"
end

module Outer
  class Inner < Struct.new(:n)
    def one? = n == 1
  end
end

class Outer::Pathed < Struct.new(:n)
  def two? = n == 2
end

class ::Rooted < Struct.new(:n)
  def three? = n == 3
end

class Spread < Struct.new(
  :left,
  :right
)
  def both? = left && right
end
