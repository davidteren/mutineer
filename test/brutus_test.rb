# frozen_string_literal: true

require_relative "test_helper"

class BrutusTest < Minitest::Test
  def test_version_is_a_non_empty_string
    assert_kind_of String, Brutus::VERSION
    refute_empty Brutus::VERSION
  end
end
