# frozen_string_literal: true

require "minitest/autorun"
require_relative "widget"

class WidgetStrongTest < Minitest::Test
  def test_name_required = refute Widget.new("").valid?
  def test_parts_cascade = assert_includes Widget.cascades, :parts
end
