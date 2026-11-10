# frozen_string_literal: true

require "minitest/autorun"
require_relative "hook_load_time"

# Checks only the value computed at load, so a mutant is killed only when it
# is in place before the file's last line runs (#348).
class HookLoadTimeTest < Minitest::Test
  def test_total_computed_at_load
    assert_equal 4, HOOK_LOAD_TIME_TOTAL
  end

  def test_bumped_computed_at_load
    assert_equal 3, HOOK_LOAD_TIME_BUMPED
  end
end
