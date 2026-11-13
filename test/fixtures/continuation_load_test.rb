# frozen_string_literal: true

require "minitest/autorun"
require_relative "continuation_load"

# Calls the continuation during the test. `>` and `>=` both hold for 20.
class ContinuationLoadTest < Minitest::Test
  def test_true
    assert ContinuationLoad.adult?(true)
  end
end
