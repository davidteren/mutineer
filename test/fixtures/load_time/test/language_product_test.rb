# frozen_string_literal: true

require "minitest/autorun"

# The boot file loads or registers the classes (#493).
class LanguageProductTest < Minitest::Test
  def test_strips_the_value
    assert_equal "en", LanguageProduct.new(" en ").language
  end

  def test_rejects_upper_case
    assert_equal [:invalid], LanguageProduct.new("EN").errors
  end

  def test_rejects_a_long_value
    assert_equal [:too_long], LanguageProduct.new("a" * 36).errors
  end

  def test_label
    assert_equal "product", LanguageProduct.new("en").label
  end
end
