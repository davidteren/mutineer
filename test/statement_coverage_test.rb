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
    Mutineer::JobPlan.coverage_selection(SOURCE, mutation, subject, @source, @map).first
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

  # PR #188 review: the tests that ran the `case` only took the first branch,
  # so they may not have reached a later `when` condition on a line Ruby does
  # not count. Since #254 they run as `:maybe`: a kill counts, and a survivor
  # is no_coverage.
  def test_a_later_when_condition_runs_the_case_tests_as_maybe
    assert_equal :maybe, selection_for(":never_matched_either")
  end

  def test_a_statement_on_the_def_line_of_a_method_no_test_calls_has_no_tests
    assert_equal :verdict, selection_for(":never_called")
  end

  # #254: Ruby counts only the first line of `verified &&\n age > 17`, and the
  # tests that ran it may not have run the right side.
  def test_the_right_side_of_a_multi_line_and_runs_the_statement_tests_as_maybe
    assert_equal :maybe, selection_for("age > 17")
  end

  # A test that runs the right side kills its mutant. A run whose tests never
  # reach it cannot tell "never ran" from "ran unchecked", so a survivor is
  # no_coverage, never a survivor.
  def test_a_maybe_mutant_is_killed_or_no_coverage
    { TEST => [1, 0], File.expand_path("fixtures/continuation_weak_test.rb", __dir__) => [0, 1] }.each do |test, want|
      config = Mutineer::Config.new(sources: [SOURCE], tests: [test], only: "Continuation.adult?",
                                    operators: ["comparison"], cache_dir: Dir.mktmpdir("mutineer-cache"),
                                    project_root: ROOT)
      agg, = Mutineer::Runner.execute(config)
      assert_equal want, [agg.killed_count, agg.no_coverage_count], File.basename(test)
      assert_equal 0, agg.survived_count, File.basename(test)
    end
  end
end
