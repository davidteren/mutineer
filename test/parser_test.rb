# frozen_string_literal: true

require_relative "test_helper"

class ParserTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/calculator.rb", __dir__)

  def test_parse_file_returns_clean_result
    result = Mutineer::Parser.parse_file(FIXTURE)
    assert_kind_of Prism::ParseResult, result
    assert_empty result.errors
    assert_kind_of Prism::ProgramNode, result.value
  end

  def test_parse_file_on_missing_file_raises_parse_error
    assert_raises(Mutineer::ParseError) do
      Mutineer::Parser.parse_file("does/not/exist.rb")
    end
  end

  def test_parse_string_valid
    assert_empty Mutineer::Parser.parse_string("a + b").errors
  end

  def test_parse_string_invalid_reports_errors_without_raising
    refute_empty Mutineer::Parser.parse_string("def foo").errors
  end

  # #392: an error the original already has does not count against the edit.
  # `def a(x, x)` is an error on every Prism version, so these hold on all.
  BROKEN = "def a(x, x)\nend\n\ndef b\n  1 + 2\nend\n"

  def test_new_errors_ignores_an_error_the_original_already_has
    refute Mutineer::Parser.new_errors?(BROKEN, BROKEN.sub("1 + 2", "1 - 2"))
  end

  def test_new_errors_reports_a_new_kind_of_error
    assert Mutineer::Parser.new_errors?(BROKEN, BROKEN.sub("1 + 2", "1 + ("))
  end

  def test_new_errors_reports_a_second_error_with_the_same_message
    assert Mutineer::Parser.new_errors?(BROKEN, BROKEN.sub("1 + 2", "def c(y, y); end"))
  end

  # cubic: one edit that removes the existing error and adds another with the
  # same message elsewhere is still a new error.
  def test_new_errors_reports_a_same_message_error_that_replaces_the_old_one
    assert Mutineer::Parser.new_errors?(BROKEN, BROKEN.sub("def a(x, x)", "def a(y, y)"))
  end

  # cubic: the same message over identical text, moved by one edit, is new.
  def test_new_errors_reports_the_same_error_moved_by_the_edit
    moved = BROKEN.sub("def a(x, x)\nend\n\ndef b\n", "def a(x)\nend\n\ndef b(x, x)\n")
    assert Mutineer::Parser.new_errors?(BROKEN, moved)
  end

  # An error after the edit keeps its identity although its offsets move.
  def test_new_errors_ignores_an_existing_error_after_the_edit
    source = "x = 1 + 2\ndef a(y, y)\nend\n"
    refute Mutineer::Parser.new_errors?(source, source.sub("1 + 2", "10000 - 20000"))
  end

  # predictability: an existing error that encloses the edit is not new. Every
  # Prism marks a constant write in a def whole, as Prism 2 marks `T += 1`.
  def test_new_errors_ignores_an_existing_error_that_encloses_the_edit
    source = "def m\n  B = 1 + 2\nend\n"
    refute Mutineer::Parser.new_errors?(source, source.sub("1 + 2", "1 - 2"))
    refute Mutineer::Parser.new_errors?(source, source.sub("1 + 2", "10 + 20"))
  end

  # The same error growing past the original's end still encloses the edit;
  # one that now starts inside the edit is new.
  def test_new_errors_reports_an_error_that_starts_inside_the_edit
    source = "def m\n  B = 1\nend\n"
    assert Mutineer::Parser.new_errors?(source, source.sub("  B = 1", "  x = 1; C = 1"))
  end

  def test_new_errors_is_false_for_clean_source
    refute Mutineer::Parser.new_errors?("1 + 2", "1 - 2")
  end
end
