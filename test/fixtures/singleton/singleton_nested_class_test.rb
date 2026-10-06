# frozen_string_literal: true

require "minitest/autorun"
require_relative "singleton_nested_class"

class SingletonNestedClassTest < Minitest::Test
  def test_q
    assert_equal 2, SingletonNestedApp.q
  end

  def test_z
    assert_equal 6, SingletonNestedApp.z
  end
end
