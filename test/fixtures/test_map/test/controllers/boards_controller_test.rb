# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../app/controllers/boards_controller"

# Asserts the value BoardScoped computes, so mutants of that concern die here.
class BoardsControllerTest < Minitest::Test
  def test_show
    assert_equal 11, BoardsController.new.show(1)
  end
end
