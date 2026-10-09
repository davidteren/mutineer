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

  def test_safe_navigation_resolvable
    assert_equal [M::SafeNavigation], Mutineer::MutatorRegistry.resolve(%w[safe_navigation])
  end

  def test_range_resolvable
    assert_equal [M::RangeLiteral], Mutineer::MutatorRegistry.resolve(%w[range])
  end

  def test_negation_removal_resolvable
    assert_equal [M::NegationRemoval], Mutineer::MutatorRegistry.resolve(%w[negation_removal])
  end


  def test_chain_link_resolvable
    assert_equal [M::ChainLink], Mutineer::MutatorRegistry.resolve(%w[chain_link])
  end


  def test_operand_removal_resolvable
    assert_equal [M::OperandRemoval], Mutineer::MutatorRegistry.resolve(%w[operand_removal])
  end

  def test_array_literal_resolvable
    assert_equal [M::ArrayLiteral], Mutineer::MutatorRegistry.resolve(%w[array_literal])
  end

  def test_operator_assignment_resolvable
    assert_equal [M::OperatorAssignment], Mutineer::MutatorRegistry.resolve(%w[operator_assignment])
  end

  def test_condition_forcing_resolvable
    assert_equal [M::ConditionTrue, M::ConditionFalse],
                 Mutineer::MutatorRegistry.resolve(%w[condition_true condition_false])
  end

  def test_new_operators_are_tier2_and_not_default
    %w[string_literal regex collection_method safe_navigation range negation_removal chain_link
       operand_removal array_literal condition_true condition_false
       operator_assignment].each do |name|
      assert_equal 2, Mutineer::MutatorRegistry.tier(name), "#{name} should be tier 2"
      refute Mutineer::MutatorRegistry.default?(name), "#{name} should not be default"
      assert Mutineer::MutatorRegistry::DESCRIPTIONS.key?(name), "#{name} needs a description"
    end
  end

  def test_unknown_operator_error_suggests_a_close_name
    err = assert_raises(ArgumentError) { Mutineer::MutatorRegistry.resolve(["comparsion"]) }
    assert_equal 'Unknown operator: "comparsion" (did you mean "comparison"?)', err.message
  end

  def test_unknown_operator_error_without_a_close_name
    err = assert_raises(ArgumentError) { Mutineer::MutatorRegistry.resolve(["zzzzzz"]) }
    assert_equal 'Unknown operator: "zzzzzz"', err.message
  end
end
