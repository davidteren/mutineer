# frozen_string_literal: true

# #528: a class statement after the assignment renames the accessor and wraps
# it. Run again on a kept class, it would make `x` call itself, so reload does
# not keep this constant and builds the class again on each load.
ReopenedPoint = Struct.new(:x)

class ReopenedPoint
  alias_method :raw_x, :x

  def x = raw_x.to_i + 1

  def weak?(value) = value == 4
end
