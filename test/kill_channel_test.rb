# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# The --matrix line protocol: what the child writes and what the parent reads.
class KillChannelTest < Minitest::Test
  KC = Mutineer::KillChannel

  def written
    io = StringIO.new
    yield io
    io.string
  end

  def test_a_full_run_round_trips
    text = written do |io|
      KC.write_start(io)
      KC.write(io, KC::KILL, "/p/a_test.rb", "A#test_a")
      KC.write(io, KC::PASS, "/p/s_spec.rb", "S checks", "./s_spec.rb[1:1]")
      KC.write_end(io)
    end
    report = KC.parse(text)

    assert_equal [["/p/a_test.rb", "A#test_a", "A#test_a"]], report.killed
    assert_equal [["/p/a_test.rb", "A#test_a", "A#test_a"], ["/p/s_spec.rb", "S checks", "./s_spec.rb[1:1]"]],
                 report.ran
    assert report.started
    assert report.finished
    refute report.parallel
    assert_equal 0, report.lost
  end

  def test_a_kill_before_the_parallel_marker_is_a_serial_kill
    report = KC.parse(written do |io|
      KC.write_start(io)
      KC.write(io, KC::KILL, "/p/a_test.rb", "A#test_a")
      KC.write_parallel(io)
      KC.write(io, KC::KILL, "/p/b_test.rb", "B#test_b")
    end)
    assert report.parallel
    assert report.serial_kill
    refute report.invalid
  end

  def test_kills_only_in_the_parallel_phase_are_not_serial_kills
    report = KC.parse(written do |io|
      KC.write_start(io)
      KC.write_parallel(io)
      KC.write(io, KC::KILL, "/p/b_test.rb", "B#test_b")
    end)
    refute report.serial_kill
  end

  def test_cleanup_and_lost_lines_are_read
    report = KC.parse(written do |io|
      KC.write_start(io)
      KC.write_cleanup(io)
      KC.write_lost(io)
    end)
    assert report.cleanup
    assert_equal 1, report.lost
    refute report.invalid
  end

  # `start` first and once, `end` last and once, a test only between `start`
  # and `cleanup`/`end`, each marker once.
  def test_a_stream_out_of_order_is_invalid
    {
      "a line before start" => [[KC::PASS, "f", "n", "n"], [KC::START]],
      "a second start" => [[KC::START], [KC::START]],
      "a start after a marker" => [[KC::START], [KC::PARALLEL], [KC::START]],
      "a second parallel" => [[KC::START], [KC::PARALLEL], [KC::PARALLEL]],
      "a parallel before start" => [[KC::PARALLEL], [KC::START]],
      "a second cleanup" => [[KC::START], [KC::CLEANUP], [KC::CLEANUP]],
      "a test after cleanup" => [[KC::START], [KC::CLEANUP], [KC::KILL, "f", "n", "n"]],
      "a test after end" => [[KC::START], [KC::FINISH], [KC::PASS, "f", "n", "n"]],
      "a second end" => [[KC::START], [KC::FINISH], [KC::FINISH]],
      "an end before start" => [[KC::FINISH], [KC::START]]
    }.each do |label, lines|
      report = KC.parse(lines.map { |fields| "#{JSON.generate(fields)}\n" }.join)
      assert report.invalid, "#{label} should be invalid"
    end
  end

  def test_a_start_with_a_mode_is_a_lost_line
    report = KC.parse(%(["start","serial"]\n))
    assert_equal 1, report.lost
    refute report.started
  end

  # The child can be killed mid-write; a partial last line is lost, not read.
  def test_a_partial_last_line_counts_as_lost
    text = written { |io| KC.write(io, KC::KILL, "/p/a_test.rb", "A#test_a") } + '["kill","/p/a_test.rb","B#'
    report = KC.parse(text)
    assert_equal 1, report.killed.size
    assert_equal 1, report.lost
  end

  def test_malformed_and_unknown_lines_count_as_lost
    report = KC.parse(%(not json\n["skip","f","n","n"]\n["kill","f","n"]\n["start","sideways"]\n{"kill":1}\n))
    assert_equal 5, report.lost
    assert_empty report.ran
    refute report.started
  end

  def test_invalid_utf8_in_a_name_is_replaced_not_dropped
    name = "A#t\xff".dup.force_encoding(Encoding::UTF_8)
    report = KC.parse(written { |io| KC.write(io, KC::KILL, "/p/a_test.rb", name) })
    assert_equal ["A#t�"], report.killed.map { |_file, n, _id| n }
  end

  def test_a_write_to_a_closed_channel_does_not_raise
    io = StringIO.new
    io.close
    assert_nil KC.write(io, KC::PASS, "f", "n")
  end
end
