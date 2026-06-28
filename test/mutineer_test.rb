# frozen_string_literal: true

require_relative "test_helper"

class MutineerTest < Minitest::Test
  def test_version_is_a_non_empty_string
    assert_kind_of String, Mutineer::VERSION
    refute_empty Mutineer::VERSION
  end
end
