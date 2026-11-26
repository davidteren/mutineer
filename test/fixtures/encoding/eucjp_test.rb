# frozen_string_literal: true

require "minitest/autorun"
require_relative "eucjp"

# Kills `+` -> `-`: 1 - 2 is not 3. The source is EUC-JP; this file is UTF-8.
class EucjpTest < Minitest::Test
  def test_add
    assert_equal 3, Calc.new.add(1, 2)
  end
end
