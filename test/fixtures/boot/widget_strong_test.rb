# frozen_string_literal: true

require "minitest/autorun"
require_relative "widget"

# Strong suite: inputs chosen so every arithmetic mutation changes the result and
# is caught -> all mutants killed -> score 100%.
class WidgetStrongTest < Minitest::Test
  def test_price
    assert_equal 6, Widget.new.price(3)   # *->/ : 3/2=1, *->+ : 5, etc. all differ
  end

  def test_total
    assert_equal 5, Widget.new.total(2, 3) # +->- : -1, etc. all differ
  end
end
