# frozen_string_literal: true

require "minitest/autorun"
require_relative "singleton_builder"

class SingletonBuilderTest < Minitest::Test
  def test_m
    assert_equal 6, SingletonBuilderApp.point(3).m
  end
end
