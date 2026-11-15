# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/greeter"

class GreetableTest < Minitest::Test
  def test_greets_alice
    assert_equal "Hello, alice", Greeter.new.greet_alice
  end
end
