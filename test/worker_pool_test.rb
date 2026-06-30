# frozen_string_literal: true

require_relative "test_helper"

class WorkerPoolTest < Minitest::Test
  # #4 regression: a result larger than the OS pipe buffer (~64KB) used to
  # deadlock — the child blocked writing before it could exit, so it was never
  # reaped and the parent never read. Timeout-guarded so a regression fails
  # loudly instead of hanging the suite.
  def test_large_result_does_not_deadlock
    require "timeout"
    big = "x" * 500_000 # ~500KB, well over the pipe buffer
    results = Timeout.timeout(30) do
      Mutineer::WorkerPool.new(2).run([[1], [2]]) do |_|
        Mutineer::Result.skipped(big)
      end
    end
    assert_equal [big.bytesize, big.bytesize], results.map { |r| r.details.bytesize }
  end

  # #21: stop_when halts scheduling after the first matching result; later items
  # are left unscheduled (nil). jobs=1 makes the order deterministic.
  def test_stop_when_halts_after_match
    items = (0...10).map { |i| [i] }
    results = Mutineer::WorkerPool.new(1).run(items, stop_when: ->(r) { r.survived? }) do |i|
      i == 2 ? Mutineer::Result.survived : Mutineer::Result.killed
    end
    assert_predicate results[2], :survived?
    assert(results[5..].all?(&:nil?), "items after the first survivor should be unscheduled (nil)")
  end

  def test_no_stop_when_runs_everything
    items = (0...5).map { |i| [i] }
    results = Mutineer::WorkerPool.new(2).run(items) { |_| Mutineer::Result.survived }
    assert_equal 5, results.compact.size, "without stop_when every item runs"
  end

  def test_returns_one_result_per_item_in_input_order
    items = (0...10).map { |i| [i] }
    results = Mutineer::WorkerPool.new(3).run(items) do |i|
      Mutineer::Result.skipped(i.to_s) # details carries the index
    end
    assert_equal 10, results.size
    assert_equal (0...10).map(&:to_s), results.map(&:details)
  end

  def test_single_slot_matches_input_order
    items = (0...5).map { |i| [i] }
    results = Mutineer::WorkerPool.new(1).run(items) { |i| Mutineer::Result.skipped(i.to_s) }
    assert_equal %w[0 1 2 3 4], results.map(&:details)
  end

  def test_mixed_verdicts_counted_correctly
    items = [[:killed], [:survived], [:killed], [:survived]]
    results = Mutineer::WorkerPool.new(2).run(items) do |verdict|
      verdict == :killed ? Mutineer::Result.killed : Mutineer::Result.survived
    end
    agg = Mutineer::AggregateResult.new(results)
    assert_equal 2, agg.killed_count
    assert_equal 2, agg.survived_count
  end

  def test_crashing_child_becomes_error_not_a_parent_crash
    capture_subprocess_io do
      results = Mutineer::WorkerPool.new(2).run([[1], [2]]) do |n|
        raise "boom" if n == 1

        Mutineer::Result.killed
      end
      assert_equal 2, results.size
      assert_predicate results[0], :error?  # the crashed child
      assert_predicate results[1], :killed?
    end
  end

  # L1: replaces the flaky wall-clock `parallel < 4*sleep` assertion. Each worker
  # records its CLOCK_MONOTONIC start/finish (system-wide, comparable across
  # processes); with size 4 and 4 jobs the intervals MUST overlap. A serial run
  # would have zero overlap, so this is deterministic, not timing-threshold luck.
  def test_workers_run_concurrently
    items = Array.new(4) { [0.2] }
    results = Mutineer::WorkerPool.new(4).run(items) do |s|
      a = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep s
      b = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Mutineer::Result.skipped("#{a} #{b}")
    end
    intervals = results.map { |r| r.details.split.map(&:to_f) }
    overlap = intervals.combination(2).any? { |(a1, a2), (b1, b2)| a1 < b2 && b1 < a2 }
    assert overlap, "expected at least two workers to run concurrently"
  end

  def test_empty_items_returns_empty
    assert_empty Mutineer::WorkerPool.new(2).run([]) { Mutineer::Result.killed }
  end

  # R6: a fork failure with nothing running cannot make progress -> re-raise
  # (rather than spin forever). Singleton `fork` shadows Kernel#fork in the pool.
  def test_eagain_with_nothing_running_reraises
    pool = Mutineer::WorkerPool.new(1)
    def pool.fork(*) = raise Errno::EAGAIN

    assert_raises(Errno::EAGAIN) { pool.run([[1]]) { Mutineer::Result.killed } }
  end

  # R6: a partial/garbage Marshal stream from a dead worker degrades to an error
  # Result instead of crashing the whole pool; an empty stream too.
  def test_partial_marshal_stream_becomes_error
    pool = Mutineer::WorkerPool.new(1)
    assert_predicate pool.send(:decode, "\x04\x08not-a-valid-marshal-payload"), :error?
    assert_predicate pool.send(:decode, ""), :error?
  end
end
