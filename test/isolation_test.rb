# frozen_string_literal: true

require_relative "test_helper"

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
