# frozen_string_literal: true

require "minitest/autorun"
require_relative "slug"

# Deliberately passes a title with no surrounding whitespace. So replacing
# `title.strip` with `title` survives undetected — nothing checks that the
# whitespace is removed.
class SlugTest < Minitest::Test
  def test_title_of_a_clean_title
    assert_equal "Hello", Slug.new.title_of("Hello")
  end
end
