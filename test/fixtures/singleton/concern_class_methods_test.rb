# frozen_string_literal: true

require "minitest/autorun"
require_relative "concern_class_methods"

class ConcernClassMethodsTest < Minitest::Test
  def test_scaled
    assert_equal 6, ConcernProduct.scaled(2)
    assert_equal 9, ConcernProduct.scaled(3)
  end

  def test_doubled
    assert_equal 4, ConcernProduct.new.doubled(2)
    assert_equal 6, ConcernProduct.new.doubled(3)
  end
end
