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

  def test_new_tier2_operators_present_and_resolvable
    assert_equal [M::StringLiteral, M::RegexLiteral, M::CollectionMethod],
                 Mutineer::MutatorRegistry.resolve(%w[string_literal regex collection_method])
  end

  def test_new_operators_are_tier2_and_not_default
    %w[string_literal regex collection_method].each do |name|
      assert_equal 2, Mutineer::MutatorRegistry.tier(name), "#{name} should be tier 2"
      refute Mutineer::MutatorRegistry.default?(name), "#{name} should not be default"
      assert Mutineer::MutatorRegistry::DESCRIPTIONS.key?(name), "#{name} needs a description"
    end
  end
end
