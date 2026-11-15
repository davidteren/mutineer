# frozen_string_literal: true

# #418: the Fizzy `DayTimelinesScoped#day` shape, a def-level rescue whose
# body is one statement.
class DayLookup
  def day(raw)
    Integer(raw)
  rescue ArgumentError
    :not_found
  end
end
