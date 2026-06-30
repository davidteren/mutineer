# frozen_string_literal: true

require_relative "test_helper"

class ResultTest < Minitest::Test
  def test_killed
    assert_predicate Mutineer::Result.killed, :killed?
    refute_predicate Mutineer::Result.killed, :survived?
  end

  def test_survived
    assert_predicate Mutineer::Result.survived, :survived?
  end

  def test_error_carries_details
    r = Mutineer::Result.error("oops")
    assert_predicate r, :error?
    assert_equal "oops", r.details
  end

  def test_error_without_details
    assert_nil Mutineer::Result.error.details
  end

  def test_timeout
    assert_predicate Mutineer::Result.timeout, :timeout?
  end

  def test_skipped_distinct_from_error
    r = Mutineer::Result.skipped
    assert_predicate r, :skipped?
    refute_predicate r, :error?
    assert_nil r.details
  end

  def test_no_coverage
    r = Mutineer::Result.no_coverage
    assert_predicate r, :no_coverage?
    refute_predicate r, :killed?
    refute_predicate r, :survived?
    assert_nil r.details
  end

  def test_uncapturable
    r = Mutineer::Result.uncapturable
    assert_predicate r, :uncapturable?
    refute_predicate r, :no_coverage?
    refute_predicate r, :killed?
    refute_predicate r, :survived?
    assert_nil r.details
  end

  # #10: a suppressed equivalent mutant — a pre-fork classification like
  # no_coverage, excluded from the score denominator.
  def test_ignored
    r = Mutineer::Result.ignored
    assert_predicate r, :ignored?
    refute_predicate r, :survived?
    refute_predicate r, :killed?
    assert_nil r.id
  end

  # #10: ignored is excluded from killed+survived, so suppressing every survivor
  # reaches 100% (killed=5, survived=0, ignored=2 -> 100.0).
  def test_ignored_excluded_from_denominator_reaches_100
    results = Array.new(5) { Mutineer::Result.killed } + Array.new(2) { Mutineer::Result.ignored }
    agg = Mutineer::AggregateResult.new(results)
    assert_equal 5, agg.covered_count
    assert_equal 2, agg.ignored_count
    assert_equal 100.0, agg.mutation_score
    assert_equal 7, agg.total
  end

  # #11: by_source splits a mixed-file result list into per-file AggregateResults
  # with correct per-file scores, reusing the same count/score methods.
  def test_by_source_groups_into_per_file_aggregates
    a = subject("a.rb")
    b = subject("b.rb")
    results = [
      Mutineer::Result.killed.with(subject: a),
      Mutineer::Result.survived.with(subject: a),
      Mutineer::Result.killed.with(subject: b),
      Mutineer::Result.killed.with(subject: b)
    ]
    by_source = Mutineer::AggregateResult.new(results).by_source

    assert_equal ["a.rb", "b.rb"], by_source.keys.sort
    assert_equal 50.0, by_source["a.rb"].mutation_score
    assert_equal 100.0, by_source["b.rb"].mutation_score
    assert_instance_of Mutineer::AggregateResult, by_source["a.rb"]
  end

  # Bare results (no subject — only built in unit tests) are skipped so file keys
  # stay sortable strings.
  def test_by_source_skips_subjectless_results
    by_source = Mutineer::AggregateResult.new([Mutineer::Result.killed]).by_source
    assert_empty by_source
  end

  def subject(file)
    Mutineer::Subject.new(file: file, namespace: ["X"], name: :m, singleton: false, def_node: nil)
  end

  def test_each_factory_has_a_distinct_status
    statuses = [
      Mutineer::Result.killed, Mutineer::Result.survived, Mutineer::Result.error,
      Mutineer::Result.timeout, Mutineer::Result.skipped, Mutineer::Result.no_coverage,
      Mutineer::Result.uncapturable, Mutineer::Result.ignored
    ].map(&:status)
    assert_equal statuses, statuses.uniq
  end
end
