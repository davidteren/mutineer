# frozen_string_literal: true

require "minitest/autorun"
require_relative "alpha"

File.write(ENV["MUTINEER_SENTINEL"], "#{Process.pid} #{File.basename(__FILE__)}\n", mode: "a") if ENV["MUTINEER_SENTINEL"]

class SharedAlphaTest < Minitest::Test
  def test_double
    assert_equal 6, SharedAlpha.double(3)
    refute ENV["MUTINEER_FLUNK"]
  end
end
