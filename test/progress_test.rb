# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class ProgressTest < Minitest::Test
  def lines_for(total, ticks: total)
    io = StringIO.new
    progress = Mutineer::Progress.new(total, io: io)
    ticks.times { progress.tick }
    io.string.lines.map(&:chomp)
  end

  def test_prints_one_line_per_ten_percent_step
    lines = lines_for(200)
    assert_equal 10, lines.size
    assert_equal "[mutineer] 20/200 mutants (10%)", lines.first
    assert_equal "[mutineer] 200/200 mutants (100%)", lines.last
  end

  def test_small_runs_print_every_completion
    lines = lines_for(3)
    assert_equal ["[mutineer] 1/3 mutants (33%)",
                  "[mutineer] 2/3 mutants (66%)",
                  "[mutineer] 3/3 mutants (100%)"], lines
  end

  def test_early_stop_leaves_progress_partial
    lines = lines_for(100, ticks: 42)
    assert_equal "[mutineer] 40/100 mutants (40%)", lines.last
  end

  def test_zero_total_never_prints_or_divides
    assert_empty lines_for(0, ticks: 3)
  end

  def test_concurrent_ticks_count_exactly_once_each
    io = StringIO.new
    progress = Mutineer::Progress.new(40, io: io)
    Array.new(4) { Thread.new { 10.times { progress.tick } } }.each(&:join)
    # The mutex covers increment+compare+print, so the ten 10%-step lines are
    # fully deterministic regardless of interleaving — assert the exact set,
    # which a double-count or missed boundary anywhere in the middle would break.
    assert_equal((1..10).map { |s| "[mutineer] #{s * 4}/40 mutants (#{s * 10}%)" },
                 io.string.lines.map(&:chomp))
  end

  # Pins the default stream: progress must go to stderr, never stdout — the
  # `--format json` byte-exact stdout contract depends on it.
  def test_default_stream_is_stderr
    out, err = capture_io do
      progress = Mutineer::Progress.new(2)
      2.times { progress.tick }
    end
    assert_includes err, "[mutineer] 2/2 mutants (100%)"
    assert_empty out
  end
end
