# frozen_string_literal: true

require "minitest/autorun"

class BuilderCatalogTest < Minitest::Test
  def test_all
    assert_equal [6], BuilderCatalog::ALL
  end
end
