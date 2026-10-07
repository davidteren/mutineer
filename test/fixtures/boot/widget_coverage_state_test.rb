# frozen_string_literal: true

require "minitest/autorun"
require "coverage"
require_relative "widget"

# #228: appends the Coverage state each time it runs (capture, clean check,
# and every mutant) to the file MUTINEER_COVERAGE_STATE_LOG names.
class WidgetCoverageStateTest < Minitest::Test
  def test_price
    log = ENV.fetch("MUTINEER_COVERAGE_STATE_LOG", nil)
    File.write(log, "#{Coverage.state}\n", mode: "a") if log
    assert_equal 6, Widget.new.price(3)
  end
end
