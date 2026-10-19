# frozen_string_literal: true

require "minitest/autorun"
require_relative "concern_class_methods"

class ConcernClassMethodsTest < Minitest::Test
  def test_scaled
    assert_equal 6, ConcernProduct.scaled(2)
    assert_equal 9, ConcernProduct.scaled(3)
  end

  def test_halved
    assert_equal 2, ConcernProduct.new.halved(4)
    assert_equal 3, ConcernProduct.new.halved(6)
  end

  def test_doubled
    assert_equal 4, ConcernProduct.new.doubled(2)
    assert_equal 6, ConcernProduct.new.doubled(3)
  end
end
