# frozen_string_literal: true

require "minitest/autorun"
require_relative "constant_reload"

class ConstantReloadTest < Minitest::Test
  def test_greet
    assert_equal "Hello, Ada!", ConstantReload.greet("Ada")
    assert_equal "Hello", ConstantReload.greet("A" * 11)
    assert_equal "Hello, AAAAAAAAAA!", ConstantReload.greet("A" * 10)
  end
end
