# frozen_string_literal: true

require_relative "test_helper"

class MutatorRegistryTest < Minitest::Test
  M = Mutineer::Mutators

  def test_default_resolves_all_five
    assert_equal [M::Arithmetic, M::Comparison, M::BooleanConnector,
                  M::BooleanLiteral, M::StatementRemoval],
                 Mutineer::MutatorRegistry.resolve
  end

  def test_subset
    assert_equal [M::Arithmetic, M::Comparison],
                 Mutineer::MutatorRegistry.resolve(%w[arithmetic comparison])
  end

  def test_single
    assert_equal [M::Arithmetic], Mutineer::MutatorRegistry.resolve(%w[arithmetic])
  end

  def test_empty_list
    assert_empty Mutineer::MutatorRegistry.resolve([])
  end

  def test_unknown_raises_with_name
    e = assert_raises(ArgumentError) { Mutineer::MutatorRegistry.resolve(%w[bogus]) }
    assert_includes e.message, "bogus"
  end

  def test_default_names_constant
    assert_equal %w[arithmetic comparison boolean_connector boolean_literal statement_removal],
                 Mutineer::MutatorRegistry::DEFAULT_NAMES
  end
end
