# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/shelf"

class ShelfTest < Minitest::Test
  def test_double
    assert_equal 6, Shelf.double(3)
  end

  def test_tax
    assert Shelf.tax(1)
  end

  def test_bump
    assert_equal 3, Shelf::BUMPED
  end

  def test_short
    assert_equal 3, Shelf::SHORT
  end

  def test_half
    assert_equal 4, Shelf.half(8)
  end

  def test_ping
    assert Shelf.ping(1)
  end
end
