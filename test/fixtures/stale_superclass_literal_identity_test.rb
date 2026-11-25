# frozen_string_literal: true

require "minitest/autorun"
require_relative "stale_superclass_literal"

# A new LiteralFields object would fail the last line for every mutant.
class StaleSuperclassLiteralIdentityTest < Minitest::Test
  def test_weak_runs_and_the_row_keeps_its_parent
    LiteralRow.new(4).weak?
    assert_kind_of LiteralFields, LiteralRow.new(1)
  end
end
