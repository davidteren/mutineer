# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"

class IsolationTest < Minitest::Test
  def test_exit_zero_is_survived
    assert_predicate Mutineer::Isolation.run { 0 }, :survived?
  end

  def test_exit_one_is_killed
    assert_predicate Mutineer::Isolation.run { 1 }, :killed?
  end

  def test_exit_two_is_error
    assert_predicate Mutineer::Isolation.run { 2 }, :error?
  end

  def test_explicit_exit_is_honoured
    assert_predicate(Mutineer::Isolation.run { exit 1 }, :killed?)
  end

  def test_unhandled_exception_is_error
    # Child writes the cause to stderr then exits 2; silence it here.
    capture_subprocess_io do
      assert_predicate(Mutineer::Isolation.run { raise "boom" }, :error?)
    end
  end

  # --- stdout silencing at the fork boundary ------------------------------
  # The test runners do not silence output; Isolation.run does it once, right
  # after fork. These cases replace the runner-level silencing tests.

  NOISY_MINITEST = File.expand_path("fixtures/noisy_minitest_test.rb", __dir__)

  def test_child_stdout_is_silenced
    out, = capture_subprocess_io do
      Mutineer::Isolation.run do
        puts "RUBY-LEVEL"
        STDOUT.write("FD-LEVEL\n")
        system("echo SUBPROCESS")
        0
      end
    end
    assert_empty out
  end

  def test_minitest_output_is_silenced
    result = nil
    out, = capture_subprocess_io do
      result = Mutineer::Isolation.run { Mutineer::TestRunners::Minitest.run([NOISY_MINITEST]) }
    end
    assert_predicate result, :survived?
    assert_empty out, "test output should be silenced"
  end

  # The parent may hold a StringIO in $stdout (here: capture_io). The child must
  # still give the test a real IO, or `$stdout.reopen` raises TypeError.
  def test_child_stdout_is_a_real_io_when_parent_stdout_is_a_stringio
    result = nil
    capture_io do
      result = Mutineer::Isolation.run do
        $stdout.reopen(File::NULL)
        $stdout.equal?(STDOUT) ? 0 : 1
      end
    end
    assert_predicate result, :survived?
  end

  # Nothing in the parent changes: its stdout still reaches fd 1 after the run.
  def test_parent_stdout_is_untouched
    out, = capture_subprocess_io do
      Mutineer::Isolation.run { puts "CHILD"; 0 }
      $stdout.puts "AFTER-RUN"
    end
    assert_equal "AFTER-RUN\n", out
  end

  # Stderr stays open in the child.
  def test_child_stderr_passes_through
    _, err = capture_subprocess_io { Mutineer::Isolation.run { STDERR.puts "CHILD-ERR"; 0 } }
    assert_includes err, "CHILD-ERR"
  end

  # The child's own diagnostic goes to fd 2, also when the block left $stderr
  # (and $stdout) as a StringIO.
  def test_error_diagnostic_reaches_stderr_after_block_swaps_streams
    result = nil
    _, err = capture_subprocess_io do
      result = Mutineer::Isolation.run do
        $stdout = StringIO.new
        $stderr = StringIO.new
        raise "boom"
      end
    end
    assert_predicate result, :error?
    assert_includes err, "[mutineer-child] RuntimeError: boom"
  end

  def test_runaway_child_times_out
    result = Mutineer::Isolation.run(timeout: 1) { sleep 30 }
    assert_predicate result, :timeout?
  end

  # Signal death (SIGSEGV/SIGKILL from the child itself, not our timeout) decodes
  # to error, NOT timeout — timeout is a parent-side deadline fact, not signaled?.
  def test_signal_death_is_error_not_timeout
    result = Mutineer::Isolation.run { Process.kill("KILL", Process.pid) }
    assert_predicate result, :error?
  end

  # #5: a compact namespace element "A::B" stays ONE wrapper `class A::B`
  # (nesting [A::B]) — not split into `module A; class B` (nesting [A::B, A]),
  # which would resolve an A-only constant under redefine but not reload.
  def test_nesting_keywords_keeps_compact_path_as_single_wrapper
    Object.const_set(:CmpKW, Module.new) unless Object.const_defined?(:CmpKW)
    CmpKW.const_set(:Leaf, Class.new) unless CmpKW.const_defined?(:Leaf)
    assert_equal [["class", "CmpKW::Leaf"]], Mutineer::Isolation.nesting_keywords(["CmpKW::Leaf"])
  end

  def test_nesting_keywords_mixed_simple_and_compact
    Object.const_set(:OuterNS, Module.new) unless Object.const_defined?(:OuterNS)
    OuterNS.const_set(:Mid, Module.new) unless OuterNS.const_defined?(:Mid)
    OuterNS::Mid.const_set(:Deep, Class.new) unless OuterNS::Mid.const_defined?(:Deep)
    assert_equal [["module", "OuterNS"], ["class", "Mid::Deep"]],
                 Mutineer::Isolation.nesting_keywords(["OuterNS", "Mid::Deep"])
  end

  def test_no_zombies_left_behind
    Mutineer::Isolation.run { 0 }
    # If the child were not reaped, waitpid(-1) would return it; ECHILD means
    # there are no unreaped children.
    assert_raises(Errno::ECHILD) { Process.wait(-1, Process::WNOHANG) }
  end

  def test_apply_whole_file_loads_by_absolute_path
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { Dir.mkdir("lib"); Mutineer::Isolation.apply_whole_file("$loaded_from = __FILE__\n", "lib/x.rb") }
      assert_equal File.join(File.realpath(dir), "lib"), File.dirname($loaded_from)
    end
  end

  # --- the --matrix channel ------------------------------------------------
  # With channel: true the block gets a pipe for KillChannel lines, and the
  # Result carries them as Kills. The verdict is the one a run without
  # --matrix gives; the row is complete only with `start`, `end`, no lost line,
  # and kills that agree with the verdict.

  KC = Mutineer::KillChannel
  T_A = ["/p/t_test.rb", "T#test_a", "T#test_a"].freeze
  T_B = ["/p/t_test.rb", "T#test_b", "T#test_b"].freeze

  def send_kill(io, name) = KC.write(io, KC::KILL, "/p/t_test.rb", name)
  def send_pass(io, name) = KC.write(io, KC::PASS, "/p/t_test.rb", name)
  def send_start(io, parallel: false) = KC.write_start(io, parallel: parallel)
  def send_end(io) = KC.write_end(io)

  def test_without_a_channel_the_block_gets_nil_and_the_result_no_row
    result = Mutineer::Isolation.run { |channel| channel.nil? ? 0 : 1 }
    assert_predicate result, :survived?
    assert_nil result.kills
  end

  def test_a_full_report_makes_a_complete_row
    result = Mutineer::Isolation.run(channel: true) do |io|
      send_start(io)
      send_kill(io, "T#test_a")
      send_pass(io, "T#test_b")
      send_end(io)
      1
    end
    assert_predicate result, :killed?
    assert_equal [T_A], result.kills.killed_by
    assert_equal [T_A, T_B], result.kills.ran
    assert result.kills.complete
  end

  def test_a_full_survivor_report_is_complete
    result = Mutineer::Isolation.run(channel: true) do |io|
      send_start(io)
      send_pass(io, "T#test_a")
      send_end(io)
      0
    end
    assert_predicate result, :survived?
    assert result.kills.complete
  end

  # Without `end` nothing shows the suite finished: a pass then exit 0 is a
  # survivor, but its row cannot claim every test ran.
  def test_a_row_without_end_is_incomplete
    result = Mutineer::Isolation.run(channel: true) do |io|
      send_start(io)
      send_pass(io, "T#test_a")
      0
    end
    assert_predicate result, :survived?
    refute result.kills.complete
  end

  # A recorder that never armed sends no `start`, so its row lists no tests
  # and must not read as a complete survivor.
  def test_a_row_without_start_is_incomplete
    result = Mutineer::Isolation.run(channel: true) do |io|
      send_end(io)
      0
    end
    assert_predicate result, :survived?
    refute result.kills.complete
  end

  def test_a_lost_line_makes_the_row_incomplete
    result = Mutineer::Isolation.run(channel: true) do |io|
      send_start(io)
      io.write("not json\n")
      send_end(io)
      0
    end
    refute result.kills.complete
  end

  # The parent reads while it waits; a child with more to say than a pipe
  # buffer would otherwise block on write and be scored a timeout.
  def test_more_than_a_pipe_buffer_of_lines_does_not_stall_the_child
    result = Mutineer::Isolation.run(timeout: 5, channel: true) do |io|
      send_start(io)
      5_000.times { |i| send_kill(io, "T#test_#{i.to_s.rjust(40, "0")}") }
      send_end(io)
      1
    end
    assert_predicate result, :killed?
    assert_equal 5_000, result.kills.killed_by.size
    assert result.kills.complete
  end

  # The run without --matrix stops at the first failure and exits killed, so a
  # named kill makes the mutant killed whatever happens after it.
  def test_a_timeout_after_a_kill_is_killed_and_incomplete
    result = Mutineer::Isolation.run(timeout: 1, channel: true) do |io|
      send_start(io)
      send_kill(io, "T#test_a")
      sleep 30
    end
    assert_predicate result, :killed?
    assert_equal [T_A], result.kills.killed_by
    refute result.kills.complete
  end

  def test_an_exit_zero_after_a_kill_is_killed_and_incomplete
    result = Mutineer::Isolation.run(channel: true) do |io|
      send_start(io)
      send_kill(io, "T#test_a")
      exit 0
    end
    assert_predicate result, :killed?
    refute result.kills.complete
  end

  def test_a_crash_after_a_kill_is_killed_and_incomplete
    result = Mutineer::Isolation.run(channel: true) do |io|
      send_start(io)
      send_kill(io, "T#test_a")
      Process.kill(:KILL, Process.pid)
    end
    assert_predicate result, :killed?
    refute result.kills.complete
  end

  def test_an_error_after_a_kill_is_killed_and_incomplete
    capture_subprocess_io do
      result = Mutineer::Isolation.run(channel: true) do |io|
        send_start(io)
        send_kill(io, "T#test_a")
        raise "boom"
      end
      assert_predicate result, :killed?
      refute result.kills.complete
    end
  end

  # Under parallelize_me! the stop cannot skip queued tests, so a run without
  # --matrix still reaches the timeout; the matrix keeps that verdict.
  def test_a_parallel_run_keeps_its_timeout_after_a_kill
    result = Mutineer::Isolation.run(timeout: 1, channel: true) do |io|
      send_start(io, parallel: true)
      send_kill(io, "T#test_a")
      sleep 30
    end
    assert_predicate result, :timeout?
    assert_equal [T_A], result.kills.killed_by
    refute result.kills.complete
  end

  # Kills without a `start` did not come from the armed recorder.
  def test_kills_without_start_are_not_promoted
    result = Mutineer::Isolation.run(channel: true) do |io|
      send_kill(io, "T#test_a")
      0
    end
    assert_predicate result, :survived?
    refute result.kills.complete
  end

  def test_a_timeout_without_a_kill_stays_a_timeout
    result = Mutineer::Isolation.run(timeout: 1, channel: true) do |io|
      send_start(io)
      send_pass(io, "T#test_a")
      sleep 30
    end
    assert_predicate result, :timeout?
    assert_equal [T_A], result.kills.ran
    refute result.kills.complete
  end

  def test_a_kill_with_no_named_test_is_incomplete
    result = Mutineer::Isolation.run(channel: true) do |io|
      send_start(io)
      send_end(io)
      1
    end
    assert_predicate result, :killed?
    assert_empty result.kills.killed_by
    refute result.kills.complete
  end

end
