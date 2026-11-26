# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/apply_each"

# Covers the each line and never runs its block (#493).
class ApplyEachEmptyTest < Minitest::Test
  def test_called_with_no_element
    assert_equal [], ApplyEach.apply([])
  end
end
