# frozen_string_literal: true

require "minitest/autorun"
require_relative "greeting"

# Deliberately never passes nil: tests a present user only. So the `&.` -> `.`
# mutation survives undetected — nothing checks that a nil user gives nil.
class GreetingTest < Minitest::Test
  User = Struct.new(:name)

  def test_name_of_present_user
    assert_equal "Ada", Greeting.new.name_of(User.new("Ada"))
  end
end
