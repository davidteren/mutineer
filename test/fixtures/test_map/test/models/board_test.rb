# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../app/models/board"

class BoardTest < Minitest::Test
  def test_columns
    assert_equal 2, Board.new.columns(1)
  end
end
