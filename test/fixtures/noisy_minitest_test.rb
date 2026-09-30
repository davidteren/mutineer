# frozen_string_literal: true

require "minitest/autorun"

# Passing suite that prints (fixture, excluded from Mutineer's own run) so the
# Minitest runner's silencing can be asserted.
class NoisyMinitestFixture < Minitest::Test
  def test_prints
    puts "NOISE-FROM-TEST"
    assert true
  end
end
