# frozen_string_literal: true

require "minitest/autorun"

# Exercises NO Widget line and always fails. If boot mode ran ALL --test files
# per mutant (no selection), this would kill every Widget mutant. With coverage
# selection it covers nothing, is never selected, and Widget survivors remain.
class WidgetUnrelatedFailingTest < Minitest::Test
  def test_unrelated_failure
    flunk "fails on purpose, but touches no Widget code"
  end
end
