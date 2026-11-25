# frozen_string_literal: true

require "test_helper"

class GridPointTest < ActiveSupport::TestCase
  # Reaches `origin?` only through the subclass that another file defines.
  def test_origin_through_the_subclass
    assert PinnedGridPoint.new(0).origin?
    refute PinnedGridPoint.new(1).origin?
  end
end
