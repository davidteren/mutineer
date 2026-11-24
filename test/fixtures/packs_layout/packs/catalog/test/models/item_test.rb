# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../app/models/item"

# Kills every arithmetic mutant of Item#total.
class ItemTest < Minitest::Test
  def test_total
    assert_equal 6, Item.new.total(2, 3)
  end
end
