# frozen_string_literal: true

require_relative "const_superclass"

# Another file keeps an instance and a subclass of the classes the mutant reloads.
DEFAULT_ROW = Row.new(3)

class SpecialRow < Row
end
