# frozen_string_literal: true

require "minitest/autorun"
require_relative "continuation"

class ContinuationTest < Minitest::Test
  def test_summary
    assert_equal({ yes: 2, no: 1 }, Continuation.summary({ true => 2, false => 1 }))
  end

  def test_message
    assert_equal "true\n", Continuation.message(3)
  end

  def test_note
    assert_equal "false\n", Continuation.note(3)
  end

  def test_label
    assert_equal "", Continuation.label(false)
  end

  def test_empty
    assert_equal :never_counted, Continuation.empty
  end
end
