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
      KC.write_start(io, parallel: false)
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

  def test_start_can_mark_a_parallel_run
    assert KC.parse(written { |io| KC.write_start(io, parallel: true) }).parallel
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
