# frozen_string_literal: true

# The index is an endless range on a Hash parameter. `(1..)` and `(1...)`
# are different keys, so a test that looks up `(1..)` kills the swap.
class RangeKey
  def open?(table)
    table[1..] == :open
  end
end
