# frozen_string_literal: true

require "test_helper"

# Needs the --require file test/support/tax_setup.rb (#220).
class TaxTableTest < ActiveSupport::TestCase
  def test_setup
    assert_equal 6, TAX_SETUP
  end

  def test_round
    assert_equal 7, TaxTable.round(6)
  end
end
