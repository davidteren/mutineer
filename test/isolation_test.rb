# frozen_string_literal: true

require_relative "test_helper"

class IsolationTest < Minitest::Test
  def test_exit_zero_is_survived
    assert_predicate Brutus::Isolation.run { 0 }, :survived?
  end

  def test_exit_one_is_killed
    assert_predicate Brutus::Isolation.run { 1 }, :killed?
  end

  def test_exit_two_is_error
    assert_predicate Brutus::Isolation.run { 2 }, :error?
  end

  def test_explicit_exit_is_honoured
    assert_predicate(Brutus::Isolation.run { exit 1 }, :killed?)
  end

  def test_unhandled_exception_is_error
    # Child writes the cause to stderr then exits 2; silence it here.
    capture_subprocess_io do
      assert_predicate(Brutus::Isolation.run { raise "boom" }, :error?)
    end
  end

  def test_runaway_child_times_out
    result = Brutus::Isolation.run(timeout: 1) { sleep 30 }
    assert_predicate result, :timeout?
  end

  def test_no_zombies_left_behind
    Brutus::Isolation.run { 0 }
    # If the child were not reaped, waitpid(-1) would return it; ECHILD means
    # there are no unreaped children.
    assert_raises(Errno::ECHILD) { Process.wait(-1, Process::WNOHANG) }
  end
end
