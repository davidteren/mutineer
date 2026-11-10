# frozen_string_literal: true

require "minitest/autorun"
require_relative "widget"

class WidgetWeakTest < Minitest::Test
  def test_named_is_valid = assert Widget.new("a").valid?
end
