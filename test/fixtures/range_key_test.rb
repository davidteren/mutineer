# frozen_string_literal: true

require "minitest/autorun"
require_relative "range_key"

# Kills `table[1..]` becoming `table[1...]`: the exclusive range is not the key.
class RangeKeyTest < Minitest::Test
  def test_open_matches_the_inclusive_range_key
    assert RangeKey.new.open?({ (1..) => :open })
  end
end
