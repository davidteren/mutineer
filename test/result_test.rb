# frozen_string_literal: true

require_relative "test_helper"

class ResultTest < Minitest::Test
  def test_killed
    assert_predicate Brutus::Result.killed, :killed?
    refute_predicate Brutus::Result.killed, :survived?
  end

  def test_survived
    assert_predicate Brutus::Result.survived, :survived?
  end

  def test_error_carries_details
    r = Brutus::Result.error("oops")
    assert_predicate r, :error?
    assert_equal "oops", r.details
  end

  def test_error_without_details
    assert_nil Brutus::Result.error.details
  end

  def test_timeout
    assert_predicate Brutus::Result.timeout, :timeout?
  end

  def test_skipped_distinct_from_error
    r = Brutus::Result.skipped
    assert_predicate r, :skipped?
    refute_predicate r, :error?
    assert_nil r.details
  end

  def test_no_coverage
    r = Brutus::Result.no_coverage
    assert_predicate r, :no_coverage?
    refute_predicate r, :killed?
    refute_predicate r, :survived?
    assert_nil r.details
  end

  def test_each_factory_has_a_distinct_status
    statuses = [
      Brutus::Result.killed, Brutus::Result.survived, Brutus::Result.error,
      Brutus::Result.timeout, Brutus::Result.skipped, Brutus::Result.no_coverage
    ].map(&:status)
    assert_equal statuses, statuses.uniq
  end
end
