# frozen_string_literal: true

# #528: a class constant from a builder block, with no class statement for it
# in this file. Another file holds a subclass and an instance of it.
BuilderPoint = Struct.new(:x) do
  def one? = x == 1

  def weak? = x == 9
end
