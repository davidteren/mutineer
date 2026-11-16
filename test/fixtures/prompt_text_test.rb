# frozen_string_literal: true

require "minitest/autorun"
require_relative "prompt_text"

class PromptTextTest < Minitest::Test
  def test_prompt_mentions_brevity
    assert_includes PromptText.new.prompt, "briefly"
  end

  def test_note_names_the_old_value
    assert_equal 'Saved (was: "a")', PromptText.new.note("a")
  end

  def test_greet_says_hello
    assert_equal "Hello, Ada", PromptText.new.greet("Ada")
  end
end
