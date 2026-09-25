# frozen_string_literal: true

require "minitest/autorun"

# MUTINEER_FIXTURE_FIRST sets the first test: fail, error, skip or pass.
# The second test writes MUTINEER_FIXTURE_MARKER.
class StopAtFirstFailureFixture < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  def test_a_first
    case ENV.fetch("MUTINEER_FIXTURE_FIRST")
    when "fail" then flunk "the first test fails"
    when "error" then raise "the first test raises"
    when "skip" then skip "the first test skips"
    else pass
    end
  end

  def test_b_writes_marker
    File.write(ENV.fetch("MUTINEER_FIXTURE_MARKER"), "ran")
    pass
  end
end
