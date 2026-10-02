# frozen_string_literal: true

require_relative "test_helper"

# KillMatrix is pure: these cases build Kills rows by hand and check the blind
# and redundant math, including the rows a timeout or an error left incomplete.
class KillMatrixTest < Minitest::Test
  A = ["a_test.rb", "ATest#test_a"].freeze
  B = ["b_test.rb", "BTest#test_b"].freeze
  C = ["c_test.rb", "CTest#test_c"].freeze
  D = ["d_test.rb", "DTest#test_d"].freeze

  def row(status, killed_by, ran, complete: true)
    kills = Mutineer::Kills.new(killed_by: killed_by.sort, ran: (ran + killed_by).uniq.sort, complete: complete)
    Mutineer::Result.new(status: status, kills: kills)
  end

  def test_results_without_a_row_are_left_out
    matrix = Mutineer::KillMatrix.new([Mutineer::Result.no_coverage, Mutineer::Result.ignored,
                                       row(:survived, [], [A])])
    assert_equal 1, matrix.rows.size
    assert_equal [A], matrix.tests
  end

  def test_a_test_that_ran_and_killed_nothing_is_blind
    matrix = Mutineer::KillMatrix.new([row(:killed, [A], [B]), row(:survived, [], [A, B])])
    assert_equal [B], matrix.blind
    assert_equal 1, matrix.kill_count(A)
    assert_equal 0, matrix.kill_count(B)
  end

  def test_a_sole_killer_is_not_redundant
    matrix = Mutineer::KillMatrix.new([row(:killed, [A], [B]), row(:killed, [A, B], [])])
    assert_equal [B], matrix.redundant
  end

  # A and B are each the only other killer of the mutant they share, so both
  # are redundant on their own, and deleting both loses the kill.
  def test_redundancy_is_judged_one_test_at_a_time
    matrix = Mutineer::KillMatrix.new([row(:killed, [A, B], [C])])
    assert_equal [A, B], matrix.redundant
    assert_equal [C], matrix.blind
  end

  def test_a_test_seen_only_in_incomplete_rows_is_never_blind
    matrix = Mutineer::KillMatrix.new([row(:timeout, [], [A], complete: false),
                                       row(:survived, [], [B])])
    assert_equal [B], matrix.blind
    refute_predicate matrix, :complete?
    assert_equal 1, matrix.incomplete_rows.size
  end

  # A kill in an incomplete row did happen, so it counts: C is a killer, and it
  # makes D's kill of the same mutant redundant.
  def test_kills_in_incomplete_rows_count
    matrix = Mutineer::KillMatrix.new([row(:killed, [C, D], [], complete: false),
                                       row(:survived, [], [C, D])])
    assert_empty matrix.blind
    assert_equal [C, D], matrix.redundant
  end

  def test_tests_are_sorted_by_file_and_name
    matrix = Mutineer::KillMatrix.new([row(:killed, [D], [B]), row(:survived, [], [C, A])])
    assert_equal [A, B, C, D], matrix.tests
  end

  def test_an_empty_run_is_complete_and_empty
    matrix = Mutineer::KillMatrix.new([])
    assert_predicate matrix, :complete?
    assert_empty matrix.tests
    assert_empty matrix.blind
    assert_empty matrix.redundant
  end
end
