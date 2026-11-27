# frozen_string_literal: true

# #528: this block renames the accessor and wraps it. A second run on the
# same class would make `x` call itself, so reload keeps the class and does
# not run the block again.
AliasPoint = Struct.new(:x) do
  alias_method :raw_x, :x

  def x = raw_x.to_i + 1

  def weak?(value) = value == 4
end
