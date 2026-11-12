# frozen_string_literal: true

require "minitest/autorun"
require_relative "continuation_load"

# Never enters the continuation. The class body did, when the file loaded.
class ContinuationLoadMissTest < Minitest::Test
  def test_false
    refute ContinuationLoad.adult?(false)
  end
end
