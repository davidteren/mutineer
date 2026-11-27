# frozen_string_literal: true

require_relative "builder_constant"

# Another file keeps a subclass and an instance of the class the mutant reloads.
class BuilderSubPoint < BuilderPoint
end

BUILDER_ORIGIN = BuilderPoint.new(1)
