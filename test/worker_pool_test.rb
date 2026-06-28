# frozen_string_literal: true

require_relative "test_helper"

class WorkerPoolTest < Minitest::Test
  def test_returns_one_result_per_item_in_input_order
    items = (0...10).map { |i| [i] }
    results = Brutus::WorkerPool.new(3).run(items) do |i|
      Brutus::Result.skipped(i.to_s) # details carries the index
    end
    assert_equal 10, results.size
    assert_equal (0...10).map(&:to_s), results.map(&:details)
  end

  def test_single_slot_matches_input_order
    items = (0...5).map { |i| [i] }
    results = Brutus::WorkerPool.new(1).run(items) { |i| Brutus::Result.skipped(i.to_s) }
    assert_equal %w[0 1 2 3 4], results.map(&:details)
  end

  def test_mixed_verdicts_counted_correctly
    items = [[:killed], [:survived], [:killed], [:survived]]
    results = Brutus::WorkerPool.new(2).run(items) do |verdict|
      verdict == :killed ? Brutus::Result.killed : Brutus::Result.survived
    end
    agg = Brutus::AggregateResult.new(results)
    assert_equal 2, agg.killed_count
    assert_equal 2, agg.survived_count
  end

  def test_crashing_child_becomes_error_not_a_parent_crash
    capture_subprocess_io do
      results = Brutus::WorkerPool.new(2).run([[1], [2]]) do |n|
        raise "boom" if n == 1

        Brutus::Result.killed
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
    results = Brutus::WorkerPool.new(4).run(items) do |s|
      a = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep s
      b = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Brutus::Result.skipped("#{a} #{b}")
    end
    intervals = results.map { |r| r.details.split.map(&:to_f) }
    overlap = intervals.combination(2).any? { |(a1, a2), (b1, b2)| a1 < b2 && b1 < a2 }
    assert overlap, "expected at least two workers to run concurrently"
  end

  def test_empty_items_returns_empty
    assert_empty Brutus::WorkerPool.new(2).run([]) { Brutus::Result.killed }
  end

  # R6: a fork failure with nothing running cannot make progress -> re-raise
  # (rather than spin forever). Singleton `fork` shadows Kernel#fork in the pool.
  def test_eagain_with_nothing_running_reraises
    pool = Brutus::WorkerPool.new(1)
    def pool.fork(*) = raise Errno::EAGAIN

    assert_raises(Errno::EAGAIN) { pool.run([[1]]) { Brutus::Result.killed } }
  end

  # R6: a partial/garbage Marshal stream from a dead worker degrades to an error
  # Result instead of crashing the whole pool.
  def test_partial_marshal_stream_becomes_error
    pool = Brutus::WorkerPool.new(1)
    rd, wr = IO.pipe
    wr.write("\x04\x08not-a-valid-marshal-payload")
    wr.close
    results = [nil]
    pool.send(:collect, results, { 999 => [0, rd] }, 999)
    assert_predicate results[0], :error?
  end
end
