# frozen_string_literal: true

require "minitest/autorun"
require_relative "self_path_block"

class SelfPathBlockTest < Minitest::Test
  def test_sum
    assert_equal 2, SelfPathTarget::Calc.sum
  end

  def test_product
    assert_equal 6, SelfPathApp::Built::Calc.product
  end
end
