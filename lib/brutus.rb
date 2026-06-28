# frozen_string_literal: true

require_relative "brutus/version"
require_relative "brutus/cli"

# Future milestones uncomment their require as they implement the file.
# require_relative "brutus/config"
require_relative "brutus/parser"
require_relative "brutus/subject"
require_relative "brutus/mutation"
require_relative "brutus/project"
# require_relative "brutus/mutator_registry"
# require_relative "brutus/coverage_map"
# require_relative "brutus/runner"
# require_relative "brutus/isolation"
# require_relative "brutus/minitest_integration"
# require_relative "brutus/result"
# require_relative "brutus/reporter"
require_relative "brutus/mutators/base"
require_relative "brutus/mutators/arithmetic"
# require_relative "brutus/mutators/comparison"
# require_relative "brutus/mutators/boolean_connector"
# require_relative "brutus/mutators/boolean_literal"
# require_relative "brutus/mutators/statement_removal"
# require_relative "brutus/mutators/return_nil"

module Brutus
end
