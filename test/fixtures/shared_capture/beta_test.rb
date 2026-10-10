# frozen_string_literal: true

require "minitest/autorun"
require_relative "beta"

File.write(ENV["MUTINEER_SENTINEL"], "#{Process.pid} #{File.basename(__FILE__)}\n", mode: "a") if ENV["MUTINEER_SENTINEL"]

class SharedBetaTest < Minitest::Test
  def test_half
    assert_equal 2, SharedBeta.half(4)
  end

  def test_width
    assert_equal 4, SharedBeta::WIDTH
  end
end
