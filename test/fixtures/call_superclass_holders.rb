# frozen_string_literal: true

require_relative "call_superclass"

# Another file keeps an instance and a subclass of the class the mutant reloads.
DEFAULT_VALUE = InclusionValue.new(type: "switch", value: 1)

class SpecialValue < InclusionValue
end
