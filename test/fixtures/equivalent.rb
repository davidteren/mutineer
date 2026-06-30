# frozen_string_literal: true

# #10 fixture. `add`'s `+` would survive the weak test below (5 + 0 == 5 - 0), so
# it is marked known-equivalent with an inline disable-line comment and must be
# classified :ignored — never run. `double`'s `*` IS killed, so suppressing the
# only would-be survivor lifts the score to 100%.
class Equivalent
  def add(a, b)
    a + b # mutineer:disable-line
  end

  def double(n)
    n * 2
  end
end
