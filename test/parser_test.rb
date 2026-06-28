# frozen_string_literal: true

require_relative "test_helper"

class ParserTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/calculator.rb", __dir__)

  def test_parse_file_returns_clean_result
    result = Brutus::Parser.parse_file(FIXTURE)
    assert_kind_of Prism::ParseResult, result
    assert_empty result.errors
    assert_kind_of Prism::ProgramNode, result.value
  end

  def test_parse_file_on_missing_file_raises_parse_error
    assert_raises(Brutus::ParseError) do
      Brutus::Parser.parse_file("does/not/exist.rb")
    end
  end

  def test_parse_string_valid
    assert_empty Brutus::Parser.parse_string("a + b").errors
  end

  def test_parse_string_invalid_reports_errors_without_raising
    refute_empty Brutus::Parser.parse_string("def foo").errors
  end
end
