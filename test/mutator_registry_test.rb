# frozen_string_literal: true

require_relative "test_helper"

class MutatorRegistryTest < Minitest::Test
  M = Brutus::Mutators

  def test_default_resolves_all_five
    assert_equal [M::Arithmetic, M::Comparison, M::BooleanConnector,
                  M::BooleanLiteral, M::StatementRemoval],
                 Brutus::MutatorRegistry.resolve
  end

  def test_subset
    assert_equal [M::Arithmetic, M::Comparison],
                 Brutus::MutatorRegistry.resolve(%w[arithmetic comparison])
  end

  def test_single
    assert_equal [M::Arithmetic], Brutus::MutatorRegistry.resolve(%w[arithmetic])
  end

  def test_empty_list
    assert_empty Brutus::MutatorRegistry.resolve([])
  end

  def test_unknown_raises_with_name
    e = assert_raises(ArgumentError) { Brutus::MutatorRegistry.resolve(%w[bogus]) }
    assert_includes e.message, "bogus"
  end

  def test_default_names_constant
    assert_equal %w[arithmetic comparison boolean_connector boolean_literal statement_removal],
                 Brutus::MutatorRegistry::DEFAULT_NAMES
  end
end
