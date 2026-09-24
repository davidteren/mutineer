# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

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
end
