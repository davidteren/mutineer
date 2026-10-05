# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Uses a real coverage capture. Ruby counts no line for the later entries of a
# multi-line hash. It counts the body line of an assigned heredoc, and the def
# line when the file loads.
class StatementCoverageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SOURCE = File.expand_path("fixtures/continuation.rb", __dir__)
  TEST = File.expand_path("fixtures/continuation_test.rb", __dir__)

  def setup
    @source = File.read(SOURCE)
    @subjects = Mutineer::Project.discover([SOURCE])
    @map = Mutineer::CoverageMap.new(
      source_paths: [SOURCE], test_paths: [TEST],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    ).build_or_load
  end

  def selection_for(snippet)
    start = @source.index(snippet)
    subject = @subjects.find { |s| s.def_node.location.start_offset <= start && start < s.def_node.location.end_offset }
    mutation = Mutineer::Mutation.new(start_offset: start, end_offset: start + snippet.size,
                                      replacement: "nil", operator: :test)
    Mutineer::Runner.coverage_selection(SOURCE, mutation, subject, @source, @map).first
  end

  def test_a_later_entry_of_a_hash_runs_its_tests
    assert_equal :run, selection_for("counts.fetch(false, 0)")
  end

  def test_an_interpolation_in_a_heredoc_runs_its_tests
    assert_equal :run, selection_for("count > 0")
  end

  def test_the_opener_of_an_assigned_heredoc_runs_its_tests
    assert_equal :run, selection_for("text = <<~TEXT")
  end

  def test_a_statement_in_an_interpolation_that_did_not_run_has_no_tests
    assert_equal :verdict, selection_for(":never_reached")
  end

  def test_the_body_of_an_endless_method_has_no_tests
    assert_equal :verdict, selection_for(":never_counted")
  end

  def test_a_statement_on_the_def_line_of_a_method_no_test_calls_has_no_tests
    assert_equal :verdict, selection_for(":never_called")
  end
end
