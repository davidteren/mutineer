# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/catalog"

class CatalogTest < Minitest::Test
  def test_all
    assert_equal [6], Catalog::ALL
  end
end
