# frozen_string_literal: true

require "minitest/autorun"

# An anonymous `parallelize_me!` class whose test fails: Minitest records no
# class name, and the kill must still count as a parallel one (#191).
Class.new(Minitest::Test) do
  parallelize_me!

  def test_fails = flunk("the parallel test fails")
end
