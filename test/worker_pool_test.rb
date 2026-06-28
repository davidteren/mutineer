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

  def test_parallel_is_faster_than_serial
    items = Array.new(4) { [0.2] }
    block = ->(s) { sleep s; Brutus::Result.killed }
    parallel = elapsed { Brutus::WorkerPool.new(4).run(items, &block) }
    assert_operator parallel, :<, (4 * 0.2), "4 jobs should overlap, not run serially"
  end

  def test_empty_items_returns_empty
    assert_empty Brutus::WorkerPool.new(2).run([]) { Brutus::Result.killed }
  end

  private

  def elapsed
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end
end
