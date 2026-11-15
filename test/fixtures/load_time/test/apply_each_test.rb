# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/apply_each"

class ApplyEachTest < Minitest::Test
  def test_called_with_an_element
    ApplyEach.apply([1])
    assert ApplyEach.kept
  end
end
