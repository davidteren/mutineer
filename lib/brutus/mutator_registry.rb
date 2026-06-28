# frozen_string_literal: true

require_relative "mutators/arithmetic"
require_relative "mutators/comparison"
require_relative "mutators/boolean_connector"
require_relative "mutators/boolean_literal"
require_relative "mutators/statement_removal"

module Brutus
  # Maps operator name -> operator class. DEFAULT_NAMES is the v1 default set
  # (all five per locked decision #2). It is kept distinct from ALL.keys because
  # M5 adds Tier-2 operators that live in ALL but are gated OFF by default, at
  # which point DEFAULT_NAMES becomes a strict subset (KTD-5).
  class MutatorRegistry
    ALL = {
      "arithmetic"        => Mutators::Arithmetic,
      "comparison"        => Mutators::Comparison,
      "boolean_connector" => Mutators::BooleanConnector,
      "boolean_literal"   => Mutators::BooleanLiteral,
      "statement_removal" => Mutators::StatementRemoval
    }.freeze
    DEFAULT_NAMES = ALL.keys.freeze

    # Returns the operator classes for the given names. Unknown names raise
    # ArgumentError immediately (caught at the CLI boundary -> exit 2).
    def self.resolve(names = DEFAULT_NAMES)
      names.map { |n| ALL.fetch(n) { raise ArgumentError, "Unknown operator: #{n.inspect}" } }
    end
  end
end
