# frozen_string_literal: true

require "minitest/autorun"
require_relative "equivalent"

# Covers both methods. `add` is exercised with a 0 operand so its `+`->`-` mutant
# would survive (hence the disable-line marker in the fixture); `double` is
# exercised strongly so its `*` mutant is killed.
class EquivalentTest < Minitest::Test
  def test_add
    assert_equal 5, Equivalent.new.add(5, 0)
  end

  def test_double
    assert_equal 6, Equivalent.new.double(3)
  end
end
