# frozen_string_literal: true

require_relative "mutators/arithmetic"
require_relative "mutators/comparison"
require_relative "mutators/boolean_connector"
require_relative "mutators/boolean_literal"
require_relative "mutators/statement_removal"
require_relative "mutators/return_nil"
require_relative "mutators/literal_mutation"
require_relative "mutators/condition_negation"

module Mutineer
  # Maps operator names to operator classes.
  #
  # DEFAULT_NAMES is the v1 default set
  # (the M4 Tier-1 + statement-removal operators per locked decision #2). The
  # three Tier-2 operators live in ALL but are OFF by default — they only run
  # when named via --operators or `operators:` in .mutineer.yml (KTD8). Keeping
  # DEFAULT_NAMES an explicit subset (not ALL.keys) is what keeps the M4 default
  # survivor set unchanged.
  class MutatorRegistry
    # All available mutator classes keyed by operator name.
    ALL = {
      "arithmetic"         => Mutators::Arithmetic,
      "comparison"         => Mutators::Comparison,
      "boolean_connector"  => Mutators::BooleanConnector,
      "boolean_literal"    => Mutators::BooleanLiteral,
      "statement_removal"  => Mutators::StatementRemoval,
      "return_nil"         => Mutators::ReturnNil,
      "literal_mutation"   => Mutators::LiteralMutation,
      "condition_negation" => Mutators::ConditionNegation
    }.freeze

    # The default Tier-1 operator set.
    DEFAULT_NAMES = %w[arithmetic comparison boolean_connector boolean_literal statement_removal].freeze
    # Tier-2 operators that remain opt-in.
    TIER2_NAMES   = %w[return_nil literal_mutation condition_negation].freeze

    # Short human-readable descriptions for each operator.
    DESCRIPTIONS = {
      "arithmetic"         => "+ <-> -, * <-> /, % -> *, ** -> *",
      "comparison"         => "< <-> <=, > <-> >=, == <-> !=",
      "boolean_connector"  => "&& <-> ||",
      "boolean_literal"    => "true <-> false, nil -> true",
      "statement_removal"  => "replace a non-final statement with nil",
      "return_nil"         => "replace a return / final expression with nil",
      "literal_mutation"   => "integer -> 0, 1, n+1; string -> empty",
      "condition_negation" => "wrap if/unless/ternary condition in !( ... )"
    }.freeze

    # Resolves operator names to classes.
    #
    # @param names [Array<String>] operator names to resolve.
    # @return [Array<Class>] mutator classes in the requested order.
    # @raise [ArgumentError] when a name is unknown.
    def self.resolve(names = DEFAULT_NAMES)
      names.map { |n| ALL.fetch(n) { raise ArgumentError, "Unknown operator: #{n.inspect}" } }
    end

    # Returns whether the operator is part of the default Tier-1 set.
    #
    # @param name [String] operator name.
    # @return [Boolean] true when the operator is default.
    def self.default?(name) = DEFAULT_NAMES.include?(name)

    # Returns the tier number for an operator name.
    #
    # @param name [String] operator name.
    # @return [Integer] 2 for Tier-2 operators, otherwise 1.
    def self.tier(name)     = TIER2_NAMES.include?(name) ? 2 : 1
  end
end
