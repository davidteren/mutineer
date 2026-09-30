# frozen_string_literal: true

require_relative "mutators/arithmetic"
require_relative "mutators/comparison"
require_relative "mutators/boolean_connector"
require_relative "mutators/boolean_literal"
require_relative "mutators/statement_removal"
require_relative "mutators/return_nil"
require_relative "mutators/literal_mutation"
require_relative "mutators/condition_negation"
require_relative "mutators/string_literal"
require_relative "mutators/regex_literal"
require_relative "mutators/collection_method"
require_relative "mutators/safe_navigation"
require_relative "mutators/range_literal"
require_relative "mutators/negation_removal"
require_relative "mutators/chain_link"
require_relative "mutators/operand_removal"
require_relative "mutators/array_literal"
require_relative "mutators/condition_forcing"

module Mutineer
  # Maps operator names to operator classes.
  #
  # DEFAULT_NAMES is the v1 default set (Tier-1 plus statement-removal).
  # The Tier-2 operators live in ALL but are OFF by default — they only
  # run when named via `--operators` or `operators:` in `.mutineer.yml`.
  # Keeping DEFAULT_NAMES an explicit subset (not ALL.keys) is what keeps
  # the default survivor set unchanged.
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
      "condition_negation" => Mutators::ConditionNegation,
      "string_literal"     => Mutators::StringLiteral,
      "regex"              => Mutators::RegexLiteral,
      "collection_method"  => Mutators::CollectionMethod,
      "safe_navigation"    => Mutators::SafeNavigation,
      "range"              => Mutators::RangeLiteral,
      "negation_removal"   => Mutators::NegationRemoval,
      "chain_link"         => Mutators::ChainLink,
      "operand_removal"    => Mutators::OperandRemoval,
      "array_literal"      => Mutators::ArrayLiteral,
      "condition_true"     => Mutators::ConditionTrue,
      "condition_false"    => Mutators::ConditionFalse
    }.freeze

    # The default Tier-1 operator set.
    DEFAULT_NAMES = %w[arithmetic comparison boolean_connector boolean_literal statement_removal].freeze
    # Tier-2 operators that remain opt-in.
    TIER2_NAMES   = %w[return_nil literal_mutation condition_negation string_literal regex collection_method
                       safe_navigation range negation_removal
                       chain_link operand_removal array_literal
                       condition_true condition_false].freeze

    # Short human-readable descriptions for each operator.
    DESCRIPTIONS = {
      "arithmetic"         => "+ <-> -, * <-> /, % -> *, ** -> *",
      "comparison"         => "< <-> <=, > <-> >=, == <-> !=",
      "boolean_connector"  => "&& <-> ||",
      "boolean_literal"    => "true <-> false, nil -> true",
      "statement_removal"  => "replace a non-final statement with nil",
      "return_nil"         => "replace a return / final expression with nil",
      "literal_mutation"   => "integer -> 0, 1, n+1; string -> empty",
      "condition_negation" => "wrap if/unless/ternary condition in !( ... )",
      "string_literal"     => "non-empty string -> \"\", empty string -> \"mutineer\"",
      "regex"              => "drop leading ^ / trailing $, swap + <-> *",
      "collection_method"  => "map<->each, all?<->any?, first<->last, min<->max, select<->reject",
      "safe_navigation"    => "&. -> .",
      "range"              => ".. <-> ...",
      "negation_removal"   => "!x, not x -> x",
      "chain_link"         => "drop one call from a chain: a.b.c -> a.c",
      "operand_removal"    => "a && b -> a, b",
      "array_literal"      => "[a, b] -> []",
      "condition_true"     => "replace an if/elsif/unless/ternary/modifier/case-in guard condition with true",
      "condition_false"    => "replace an if/elsif/unless/ternary/modifier/case-in guard condition with false"
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
