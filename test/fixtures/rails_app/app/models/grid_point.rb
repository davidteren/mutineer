# frozen_string_literal: true

# #528: a class constant from `Struct.new ... do`, with no class statement for
# it in this file. PinnedGridPoint, in another file, inherits from it.
GridPoint = Struct.new(:x) do
  def origin? = x == 0
end
