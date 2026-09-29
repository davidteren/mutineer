# frozen_string_literal: true

# #98: `module_function :compute` in ScopeHelper must not promote the unrelated
# ScopeCalculator#compute instance method defined later in the same file.
module ScopeHelper
  def compute(a, b)
    a + b
  end
  module_function :compute
end

class ScopeCalculator
  def compute(a, b)
    a + b
  end
end
