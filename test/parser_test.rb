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

  def test_new_errors_is_false_for_clean_source
    refute Mutineer::Parser.new_errors?("1 + 2", "1 - 2")
  end
end
