# frozen_string_literal: true

# #533: the superclass call reads a constant that this file builds again, and
# that reload does not keep (its builder has an argument that is not a literal).
FIELD_NAMES = %i[v].freeze

Fields533 = Struct.new(*FIELD_NAMES) do
  def total = v + 1
end

class ConstDeep < Class.new(Fields533)
  def three? = v == 3
end
