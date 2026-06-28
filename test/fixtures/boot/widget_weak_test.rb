# frozen_string_literal: true

require "minitest/autorun"
require_relative "widget"

# Weak suite: total uses a 0 operand so `+`<->`-` produce the same value and the
# `+ -> -` mutant survives undetected. price is tested strongly, so its mutants
# are killed. Net: at least one survivor, score < 100%.
class WidgetWeakTest < Minitest::Test
  def test_price
    assert_equal 6, Widget.new.price(3)   # all price mutants killed
  end

  def test_total
    assert_equal 5, Widget.new.total(5, 0) # +->- : 5-0=5 (survives)
  end
end
