# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

# The Minitest runner (wrapping MinitestIntegration) must keep its 0/1 contract.
# Run in a fork because the runner manipulates global Minitest state (autorun,
# runnables) that only makes sense in a throwaway child.
class TestRunnersMinitestTest < Minitest::Test
  FIX      = File.expand_path("../fixtures", __dir__)
  PASSING  = File.join(FIX, "calculator_strong_test.rb")
  FAILING  = File.join(FIX, "failing_minitest_test.rb")
  STOP     = File.join(FIX, "stop_at_first_failure_test.rb")
  PARALLEL = File.join(FIX, "stop_at_first_failure_parallel_test.rb")
  REPORTER = File.join(FIX, "stop_at_first_failure_reporter_test.rb")
  FIBER    = File.join(FIX, "stop_at_first_failure_fiber_test.rb")
  SEED     = File.join(FIX, "stop_at_first_failure_seed_test.rb")
  CLEANUP  = File.join(FIX, "stop_at_first_failure_cleanup_test.rb")
  LATER    = File.join(FIX, "stop_at_first_failure_later_class_test.rb")
  NESTED   = File.join(FIX, "stop_at_first_failure_nested_run_test.rb")

  # Like Isolation.run: an escaped exception is exit 2, never a false 1.
  def fork_status
    pid = fork do
      code = begin
        yield
      rescue Exception # rubocop:disable Lint/RescueException
        2
      end
      exit!(code)
    end
    _, status = Process.waitpid2(pid)
    status.exitstatus
  end

  # Returns [exit status, marker written?].
  def with_fixture_env(first)
    Dir.mktmpdir("mutineer-stop") do |dir|
      marker = File.join(dir, "marker")
      code = fork_status do
        ENV["MUTINEER_FIXTURE_FIRST"] = first
        ENV["MUTINEER_FIXTURE_MARKER"] = marker
        yield marker
      end
      [code, File.exist?(marker)]
    end
  end

  # Runs one stop fixture file. Returns [exit status, marker written?].
  def run_fixture(file, first: "fail", **kwargs)
    with_fixture_env(first) { Mutineer::TestRunners::Minitest.run([file], **kwargs) }
  end

  def test_passing_suite_returns_zero
    assert_equal 0, fork_status { Mutineer::TestRunners::Minitest.run([PASSING]) }
  end

  def test_failing_suite_returns_one
    assert_equal 1, fork_status { Mutineer::TestRunners::Minitest.run([FAILING]) }
  end

  def test_stop_at_first_failure_skips_the_tests_after_a_failure
    assert_equal [1, false], run_fixture(STOP, first: "fail", stop_at_first_failure: true)
  end

  def test_stop_at_first_failure_skips_the_tests_after_an_error
    assert_equal [1, false], run_fixture(STOP, first: "error", stop_at_first_failure: true)
  end

  def test_skip_does_not_stop_the_run
    assert_equal [0, true], run_fixture(STOP, first: "skip", stop_at_first_failure: true)
  end

  def test_passing_run_is_the_same_with_stop_at_first_failure
    assert_equal [0, true], run_fixture(STOP, first: "pass", stop_at_first_failure: true)
  end

  def test_default_runs_every_test_after_a_failure
    assert_equal [1, true], run_fixture(STOP, first: "fail")
  end

  def test_class_level_cleanup_after_super_still_runs
    Dir.mktmpdir("mutineer-stop") do |dir|
      marker = File.join(dir, "marker")
      code = fork_status do
        ENV["MUTINEER_FIXTURE_MARKER"] = marker
        Mutineer::TestRunners::Minitest.run([CLEANUP], stop_at_first_failure: true)
      end
      assert_equal [1, false, true], [code, File.exist?(marker), File.exist?("#{marker}.cleanup")]
    end
  end

  def test_later_class_does_not_start_after_a_stop
    assert_equal [1, false], run_fixture(LATER, stop_at_first_failure: true)
  end

  def test_later_class_runs_by_default
    assert_equal [1, true], run_fixture(LATER)
  end

  # `parallelize_me!` queues every test before the first result, so the
  # marker can go either way and is not checked.
  def test_failure_on_a_worker_thread_gives_a_failure
    code, = run_fixture(PARALLEL, stop_at_first_failure: true)
    assert_equal 1, code
  end

  def test_unknown_minitest_shape_falls_back_to_a_full_run
    result = with_fixture_env("fail") do
      stop = Mutineer::MinitestIntegration::StopAtFirstFailure
      stop.define_singleton_method(:hooks_for_loaded_minitest) { nil }
      Mutineer::TestRunners::Minitest.run([STOP], stop_at_first_failure: true)
    end
    assert_equal [1, true], result
  end

  def test_failure_on_a_nested_reporter_does_not_stop_the_run
    assert_equal [0, true], run_fixture(REPORTER, stop_at_first_failure: true)
  end

  def test_nested_suite_run_does_not_replace_the_outer_reporter
    assert_equal [0, true], run_fixture(NESTED, stop_at_first_failure: true)
  end

  def test_failure_in_another_fiber_stops_the_run
    assert_equal [1, false], run_fixture(FIBER, stop_at_first_failure: true)
  end

  # Returns the seed of a run with SEED set to `env_seed` (nil unsets it).
  def seed_of_run(env_seed, **kwargs)
    Dir.mktmpdir("mutineer-seed") do |dir|
      marker = File.join(dir, "seed")
      fork_status do
        env_seed ? ENV["SEED"] = env_seed : ENV.delete("SEED")
        ENV["MUTINEER_FIXTURE_MARKER"] = marker
        Mutineer::TestRunners::Minitest.run([SEED], **kwargs)
      end
      File.read(marker)
    end
  end

  def test_stop_at_first_failure_pins_the_seed
    expected = Mutineer::MinitestIntegration::STOP_AT_FIRST_FAILURE_SEED.to_s
    assert_equal expected, seed_of_run(nil, stop_at_first_failure: true)
  end

  def test_an_explicit_seed_env_wins_over_the_pinned_seed
    assert_equal "4242", seed_of_run("4242", stop_at_first_failure: true)
  end

  # The prepends stay in the process after a run. A reloaded class does not
  # register again, so this test uses a renamed copy of the fixture.
  def test_later_default_run_in_the_same_process_runs_every_test
    Dir.mktmpdir("mutineer-stop-copy") do |dir|
      copy = File.join(dir, "stop_copy_test.rb")
      File.write(copy, File.read(STOP).sub("StopAtFirstFailureFixture", "StopAtFirstFailureCopyFixture"))
      result = with_fixture_env("fail") do |marker|
        first = Mutineer::TestRunners::Minitest.run([STOP], stop_at_first_failure: true)
        stop = Mutineer::MinitestIntegration::StopAtFirstFailure
        next 3 if first != 1 || File.exist?(marker)
        next 4 unless [stop.armed_pid, stop.armed_reporter].none? && stop.stopped == false

        Mutineer::TestRunners::Minitest.run([copy])
      end
      assert_equal [1, true], result
    end
  end

  def test_stdout_is_restored_after_a_stop
    rd, wr = IO.pipe
    code, = with_fixture_env("fail") do
      rd.close
      orig = $stdout
      status = Mutineer::TestRunners::Minitest.run([STOP], stop_at_first_failure: true)
      wr.write($stdout.equal?(orig) ? "restored" : "leaked")
      wr.close
      status
    end
    wr.close
    assert_equal [1, "restored"], [code, rd.read]
  ensure
    rd&.close
  end
end
