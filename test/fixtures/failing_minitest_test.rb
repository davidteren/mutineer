# frozen_string_literal: true

require "minitest/autorun"

# Deliberately failing suite (fixture, excluded from Mutineer's own run) so the
# Minitest runner's 1 (failure) path can be asserted.
class FailingMinitestFixture < Minitest::Test
  def test_fails
    assert_equal 1, 2
  end
end
