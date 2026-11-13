# frozen_string_literal: true

require "minitest/autorun"
require_relative "lib/anchor"

# One test per path anchor. A mutant that still resolves the anchor returns
# "hihi". The `*` mutant raises, so only that test kills it (#339).
class PathAnchorTest < Minitest::Test
  def test_via_dir
    assert_equal "hihi", PathAnchor.new.via_dir(2)
  end

  def test_via_file
    assert_equal "hihi", PathAnchor.new.via_file(2)
  end

  def test_via_require
    assert_equal "hihi", PathAnchor.new.via_require(2)
  end
end
