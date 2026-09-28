# frozen_string_literal: true

require "minitest/autorun"
require_relative "tags"

# Deliberately checks only that an array comes back, not its contents. So the
# `%w[ruby rails]` -> `[]` mutation survives undetected.
class TagsTest < Minitest::Test
  def test_defaults_is_an_array
    assert_kind_of Array, Tags.new.defaults
  end
end
