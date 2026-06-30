# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/greeter"

# Strong: double(3) catches every arithmetic mutation -> 100%.
class GreeterTest < Minitest::Test
  def test_double
    assert_equal 6, Greeter.new.double(3)
  end
end
