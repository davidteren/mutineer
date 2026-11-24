# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

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

  # #392: a parse error alone does not make source invalid. Ruby must also
  # refuse to compile it. These hold on every Prism version.
  def test_invalid_is_false_for_clean_source
    refute Mutineer::Parser.invalid?("1 - 2")
  end

  def test_invalid_is_true_for_a_syntax_error
    assert Mutineer::Parser.invalid?("def m\n  1 + (\nend\n")
  end

  # Prism 2 reports this line as a dynamic constant assignment; Ruby loads it.
  def test_invalid_is_false_for_a_constant_op_assign_in_a_method
    refute Mutineer::Parser.invalid?("def m\n  T += 1\n  T ||= 2\n  T &&= 3\nend\n")
  end

  # An existing error that Ruby itself rejects still makes every mutant
  # invalid, as before #392.
  def test_invalid_is_true_when_ruby_rejects_an_existing_error
    assert Mutineer::Parser.invalid?("def a(x, x)\nend\n\ndef b\n  1 - 2\nend\n")
  end

  # The same message after the edit is not enough: Ruby refuses `T = a` in a
  # method, though Prism 2 reports it as it reports `T += a`.
  def test_invalid_is_true_when_an_edit_swaps_in_an_error_ruby_rejects
    assert Mutineer::Parser.invalid?("def m(a)\n  T = a\nend\n")
  end

  # operand_removal keeps the operand with the constant write; Ruby loads it.
  def test_invalid_is_false_when_an_edit_keeps_a_loadable_error
    refute Mutineer::Parser.invalid?("def m(a, b)\n  ((T ||= b))\nend\n")
  end

  # `--daemon` checks mutants on several threads, so overlapping compiles must
  # still leave the caller's warning setting in place. The stubbed compile
  # yields to the other threads while warnings are off.
  def test_invalid_restores_the_warning_setting_across_threads
    verbose = $VERBOSE
    $VERBOSE = false
    RubyVM::InstructionSequence.stub(:compile, ->(_source) { Thread.pass }) do
      8.times.map { Thread.new { 20.times { Mutineer::Parser.send(:compiles?, "1") } } }.each(&:join)
    end
    assert_equal false, $VERBOSE
  ensure
    $VERBOSE = verbose
  end

  # A compile warning (an assignment in a condition) does not reach stderr.
  def test_invalid_prints_no_compile_warning
    _out, err = capture_io { refute Mutineer::Parser.invalid?("def m(a)\n  T += 1 if a = 1\nend\n") }
    assert_empty err
  end
end
