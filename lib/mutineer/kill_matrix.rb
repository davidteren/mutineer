# frozen_string_literal: true

require "set"

module Mutineer
  # Which tests kill which mutants, read from the {Kills} rows of a `--matrix`
  # run. Pure: it reads results and runs nothing, and it never touches the score.
  #
  # A test is a `[file, name, id]` triple (see {Kills}); file and id identify it,
  # and every row names a test the same way (see {Runner.share_tests}). The tests it knows are
  # the ones that ran against at least one mutant of this run, so every answer
  # is relative to the run's mutants: a test of code outside the run's sources
  # kills nothing here.
  #
  # - A blind test ran in at least one complete row and killed no mutant. A
  #   test seen only in incomplete rows is never called blind.
  # - A redundant test killed at least one mutant, and each mutant it killed has
  #   another killer. Each test is judged alone: two redundant tests can be the
  #   only killers of one mutant, so delete them one at a time. Finding the
  #   smallest set of tests that keeps every kill is a set-cover problem, out of
  #   scope here.
  #
  # Kills in incomplete rows count, since they did happen. An incomplete row can
  # miss kills, so when {#complete?} is false a blind test may have killed one
  # of those mutants.
  class KillMatrix
    # The results that carry a {Kills} row, in run order.
    #
    # @return [Array<Mutineer::Result>]
    attr_reader :rows

    # @param results [Array<Mutineer::Result>] every result of the run.
    def initialize(results)
      @rows = results.select(&:kills)
      @kill_counts = Hash.new(0)
      @rows.each { |r| r.kills.killed_by.each { |test| @kill_counts[test] += 1 } }
    end

    # Every test that ran against at least one mutant, sorted by file, name and id.
    #
    # @return [Array<Array(String, String, String)>]
    def tests
      @tests ||= @rows.flat_map { |r| r.kills.ran + r.kills.killed_by }.uniq.sort
    end

    # True when every row is complete.
    #
    # @return [Boolean]
    def complete?
      @rows.all? { |r| r.kills.complete }
    end

    # The rows that are not complete.
    #
    # @return [Array<Mutineer::Result>]
    def incomplete_rows
      @rows.reject { |r| r.kills.complete }
    end

    # How many mutants `test` killed.
    #
    # @param test [Array(String, String, String)] a `[file, name, id]` test.
    # @return [Integer]
    def kill_count(test)
      @kill_counts[test]
    end

    # Tests that ran in a complete row and killed no mutant.
    #
    # @return [Array<Array(String, String, String)>] sorted.
    def blind
      @blind ||= begin
        seen = @rows.select { |r| r.kills.complete }.flat_map { |r| r.kills.ran }.to_set
        tests.select { |test| kill_count(test).zero? && seen.include?(test) }
      end
    end

    # Tests that killed a mutant, where every mutant they killed has another killer.
    #
    # @return [Array<Array(String, String, String)>] sorted.
    def redundant
      @redundant ||= begin
        sole = @rows.filter_map { |r| r.kills.killed_by.first if r.kills.killed_by.size == 1 }.to_set
        tests.select { |test| kill_count(test).positive? && !sole.include?(test) }
      end
    end
  end
end
