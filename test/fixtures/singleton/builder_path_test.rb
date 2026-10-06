# frozen_string_literal: true

require "minitest/autorun"
require_relative "builder_path"

class BuilderPathTest < Minitest::Test
  def test_allow
    assert_equal 6, PathUser::Permission.new(r: 1).allow?(3)
  end

  def test_open
    assert_equal 6, PathRelease::Gate.new.open?(3)
  end

  def test_shut
    assert_equal 6, PathRelease::Gate::Latch.new.shut?(3)
  end
end
