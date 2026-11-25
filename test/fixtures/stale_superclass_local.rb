# frozen_string_literal: true

# #533: the superclass call reads a local that an earlier line sets again on
# each load. Reload leaves it as written, so the file errors visibly.
base = Struct.new(:v) do
  def total = v + 1
end

class LocalDeep < Class.new(base)
  def three? = v == 3
end
