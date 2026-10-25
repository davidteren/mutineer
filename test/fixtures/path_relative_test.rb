# frozen_string_literal: true

require "minitest/autorun"
require_relative "path_relative"

# Kills the `*` mutant. The `+ 0` -> `- 0` mutant gives the same value, so it
# survives.
class PathRelativeTest < Minitest::Test
  def test_shout
    assert_equal "hihi", PathRelative.new.shout(2)
  end
end
