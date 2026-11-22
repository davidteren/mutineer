# frozen_string_literal: true

# #492: a value object whose superclass is a call. The daemon loads this file
# again for each mutant, which raised "superclass mismatch" before reload kept
# the live superclass.
class InclusionValue < Data.define(:type, :value)
  def switch? = type == "switch"
end
