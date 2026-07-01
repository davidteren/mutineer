# frozen_string_literal: true

# #25 fixture. `covered` is exercised by partial_good_test; `uncovered` is only
# reachable by partial_test.rb, which fails during capture — so `uncovered`'s
# mutants must be :uncapturable, not a false :no_coverage.
class Partial
  def covered(a, b)
    a + b
  end

  def uncovered(a, b)
    a * b
  end
end
