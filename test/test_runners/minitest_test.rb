# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "tmpdir"
require "stringio"

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
  MATRIX   = File.expand_path("../fixtures/matrix", __dir__)
  SERIAL_THEN_PARALLEL = File.join(MATRIX, "serial_then_parallel_test.rb")
  INTERRUPT = File.join(MATRIX, "gate_interrupt_test.rb")
  EXIT_AFTER_KILL = File.join(MATRIX, "exit_after_kill_test.rb")
  ANONYMOUS = File.join(MATRIX, "anonymous_classes_test.rb")
  ANONYMOUS_PARALLEL = File.join(MATRIX, "anonymous_parallel_test.rb")
  NESTED_PARALLEL = File.join(MATRIX, "nested_parallel_run_test.rb")
  SEED     = File.join(FIX, "stop_at_first_failure_seed_test.rb")
  CLEANUP  = File.join(FIX, "stop_at_first_failure_cleanup_test.rb")
  LATER    = File.join(FIX, "stop_at_first_failure_later_class_test.rb")
  NESTED   = File.join(FIX, "stop_at_first_failure_nested_run_test.rb")

  # Wraps each assertion in capture_subprocess_io, which reopens $stdout.
  SUBPROCESS_IO = File.join(FIX, "calculator_subprocess_io_test.rb")
  # Leaves $stdout as a StringIO, at load time and inside a test.
  STDOUT_SWAP = File.join(FIX, "calculator_stdout_swap_test.rb")

  # The child silences stdout first, as every real fork boundary does (see
  # Mutineer::ChildStdout). Like Isolation.run, an escaped exception is exit 2,
  # never a false 1.
  def fork_status
    pid = fork do
      Process.setpgid(0, 0) # lead a group, so the deadline kill reaches descendants
      Mutineer::ChildStdout.silence
      code = begin
        yield
      rescue Exception # rubocop:disable Lint/RescueException
        2
      end
      exit!(code)
    end
    status = wait_child(pid)
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

  # #132: the deadline in wait_child kills the child's process group, so the
  # child must lead one for a hung descendant to die with it.
  def test_fork_status_child_leads_its_own_process_group
    assert_equal 0, fork_status { Process.getpgrp == Process.pid ? 0 : 1 }
  end

  def test_passing_suite_returns_zero
    assert_equal 0, fork_status { Mutineer::TestRunners::Minitest.run([PASSING]) }
  end

  def test_suite_that_reopens_stdout_returns_zero
    assert_equal 0, fork_status { Mutineer::TestRunners::Minitest.run([SUBPROCESS_IO]) }
  end

  def test_suite_that_swaps_stdout_for_a_stringio_returns_zero
    assert_equal 0, fork_status { Mutineer::TestRunners::Minitest.run([STDOUT_SWAP]) }
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

  # #203: a mutant run loads its files in run order. Each class appends its
  # file's letter to the marker. File "a" also holds a parallel class ("p"),
  # which still runs after every serial class. Returns the marker text.
  def class_order(files, **kwargs)
    Dir.mktmpdir("mutineer-order") do |dir|
      marker = File.join(dir, "marker")
      paths = files.to_h do |letter|
        path = File.join(dir, "#{letter}_order_test.rb")
        body = (1..3).map do |n|
          "class FileOrder#{letter.upcase}#{n}Test < Minitest::Test\n" \
            "  def test_mark; File.write(#{marker.dump}, #{letter.dump}, mode: \"a\"); end\nend\n"
        end.join
        if letter == "a"
          body += "class FileOrderParallelTest < Minitest::Test\n  parallelize_me!\n" \
                  "  def test_mark; File.write(#{marker.dump}, \"p\", mode: \"a\"); end\nend\n"
        end
        File.write(path, "require \"minitest\"\n#{body}")
        [letter, path]
      end
      fork_status { Mutineer::TestRunners::Minitest.run(files.map { |l| paths[l] }, **kwargs) }
      File.read(marker)
    end
  end

  def test_stop_at_first_failure_runs_classes_in_file_order
    assert_equal "aaabbbp", class_order(%w[a b], stop_at_first_failure: true)
    assert_equal "bbbaaap", class_order(%w[b a], stop_at_first_failure: true)
  end

  # Minitest 5.15 and older shuffle `runnables.reject { ... }`, a new array.
  def test_file_order_survives_the_filter_of_older_minitest
    code = fork_status do
      classes = Array.new(6) { Class.new }
      Minitest::Runnable.runnables.replace(classes)
      Mutineer::MinitestIntegration.keep_file_order(classes.each_with_index.to_h)
      srand(1)
      Minitest::Runnable.runnables.reject { false }.shuffle == classes ? 0 : 1
    end
    assert_equal 0, code
  end

  def test_record_to_runs_classes_in_file_order
    IO.pipe do |_rd, wr|
      assert_equal "aaabbbp", class_order(%w[a b], record_to: wr)
      assert_equal "bbbaaap", class_order(%w[b a], record_to: wr)
    end
  end

  # --- record_to (--matrix) -------------------------------------------------
  # A matrix run never stops: every test runs, and each outcome goes to the
  # KillChannel pipe between a `start` and an `end` line. Only the outer
  # reporter's results count.

  # Runs `file` with a channel. Returns [exit status, marker written?, report].
  def record_fixture(file, first: "fail", &setup)
    rd, wr = IO.pipe
    code, marker = with_fixture_env(first) do
      rd.close
      setup&.call
      Mutineer::TestRunners::Minitest.run([file], record_to: wr)
    end
    wr.close
    [code, marker, Mutineer::KillChannel.parse(rd.read)]
  ensure
    [rd, wr].each { |io| io.close unless io.closed? }
  end

  def names(tests) = tests.map { |_file, name, _id| name }

  def test_record_to_runs_every_test_and_names_the_failure
    code, marker, report = record_fixture(STOP, first: "fail")
    assert_equal [1, true], [code, marker]
    first = "StopAtFirstFailureFixture#test_a_first"
    assert_equal [[STOP, first, first]], report.killed
    assert_equal %w[StopAtFirstFailureFixture#test_a_first StopAtFirstFailureFixture#test_b_writes_marker],
                 names(report.ran)
    assert report.started
    assert report.finished
    refute report.parallel
    assert_equal 0, report.lost
  end

  def test_record_to_counts_an_error_as_a_kill
    _, marker, report = record_fixture(STOP, first: "error")
    assert marker
    assert_equal ["StopAtFirstFailureFixture#test_a_first"], names(report.killed)
  end

  def test_record_to_sends_nothing_for_a_skip
    code, _, report = record_fixture(STOP, first: "skip")
    assert_equal 0, code
    assert_empty report.killed
    assert_equal ["StopAtFirstFailureFixture#test_b_writes_marker"], names(report.ran)
  end

  def test_record_to_ignores_a_failure_on_a_nested_reporter
    code, _, report = record_fixture(REPORTER)
    assert_equal 0, code
    assert_empty report.killed
    assert_equal 2, report.ran.size
  end

  def test_record_to_ignores_a_nested_suite_run
    code, _, report = record_fixture(NESTED)
    assert_equal 0, code
    assert_empty report.killed
    refute_includes names(report.ran), "StopAtFirstFailureInnerFixture#test_fails"
  end

  def test_record_to_names_a_failure_in_another_fiber
    code, marker, report = record_fixture(FIBER)
    assert_equal [1, true], [code, marker]
    assert_equal ["StopAtFirstFailureFiberFixture#test_a_fails"], names(report.killed)
  end

  # The stop cannot skip tests parallelize_me! already queued, so a marker
  # says where the parallel tests begin, and the parent keeps the exit status
  # for a kill in them.
  def test_record_to_marks_a_parallel_run
    _, _, report = record_fixture(PARALLEL)
    assert report.started
    assert report.parallel
    refute report.invalid
  end

  # Minitest runs the serial class first, so its kill comes before the
  # `parallel` line, and a kill the stop would have followed is told apart from
  # one in the parallel phase.
  def test_record_to_sends_the_parallel_line_after_a_serial_kill
    rd, wr = IO.pipe
    fork_status do
      rd.close
      Mutineer::TestRunners::Minitest.run([SERIAL_THEN_PARALLEL], record_to: wr)
    end
    wr.close
    text = rd.read
    lines = text.lines.map { |line| JSON.parse(line).first }
    assert_equal %w[start kill parallel pass end], lines - %w[skip unskip]
    # The later class and its test run inside balanced skip regions, after the kill.
    assert_operator lines.count("skip"), :>=, 1
    assert_operator lines.index("skip"), :>, lines.index("kill")
    report = Mutineer::KillChannel.parse(text)
    assert report.serial_kill
    assert_equal 0, report.skipping
    refute report.invalid
  ensure
    [rd, wr].each { |io| io.close unless io.closed? }
  end

  # Minitest catches an Interrupt in a test and returns, so the return proves
  # nothing: the run is cut short without an `end` line.
  def test_record_to_sends_no_end_when_an_interrupt_cut_the_run_short
    ENV["MATRIX_FIXTURE_INTERRUPT"] = "1"
    code, report = nil
    capture_subprocess_io { code, _, report = record_fixture(INTERRUPT, first: "pass") }
    assert_equal 1, code
    assert_equal ["MatrixGateInterruptTest#test_a_boundary"], names(report.killed)
    refute report.finished
  ensure
    ENV.delete("MATRIX_FIXTURE_INTERRUPT")
  end

  # An unknown Minitest shape arms nothing: no `start`, so no row can claim to
  # be complete, though the run itself still happens.
  def test_record_to_with_an_unknown_minitest_shape_sends_no_start
    code, marker, report = record_fixture(STOP, first: "fail") do
      Mutineer::MinitestIntegration::OuterReporter.define_singleton_method(:hook_for_loaded_minitest) { nil }
    end
    assert_equal [1, true], [code, marker]
    refute report.started
    assert_empty report.ran
  end

  def test_record_to_pins_the_seed
    expected = Mutineer::MinitestIntegration::STOP_AT_FIRST_FAILURE_SEED.to_s
    rd, wr = IO.pipe
    assert_equal expected, seed_of_run(nil, record_to: wr)
  ensure
    [rd, wr].each { |io| io.close unless io.closed? }
  end

  # The verdict Isolation gives EXIT_AFTER_KILL in `mode`, plain or --matrix.
  def exit_after_kill_verdict(mode, matrix:)
    ENV["MUTINEER_FIXTURE_MODE"] = mode
    capture_subprocess_io do
      @verdict = Mutineer::Isolation.run(timeout: 10, channel: matrix) do |io|
        if matrix
          Mutineer::TestRunners::Minitest.run([EXIT_AFTER_KILL], record_to: io)
        else
          Mutineer::TestRunners::Minitest.run([EXIT_AFTER_KILL], stop_at_first_failure: true)
        end
      end.status
    end
    @verdict
  ensure
    ENV.delete("MUTINEER_FIXTURE_MODE")
  end

  # #191 review: after a kill, an end in code a plain run also reaches (the
  # failing class's wrapper) keeps the exit status; an end in a test or class
  # the plain run skips is killed, as the plain run is.
  { "none" => :killed, "wrapper_exit" => :survived, "wrapper_raise" => :error,
    "later_exit" => :killed, "later_exit_two" => :killed, "later_class_exit" => :killed,
    "per_test_exit" => :killed }.each do |mode, plain|
    define_method("test_matrix_verdict_matches_a_plain_run_when_#{mode}") do
      assert_equal plain, exit_after_kill_verdict(mode, matrix: false), "plain run"
      assert_equal plain, exit_after_kill_verdict(mode, matrix: true), "matrix run"
    end
  end

  # #191 review: Minitest records no name for an anonymous class, so the id
  # adds the line that defines the method (no path), and the two tests stay apart.
  def test_record_to_tells_apart_tests_of_anonymous_classes
    _code, _marker, report = record_fixture(ANONYMOUS)
    assert_equal ["(anonymous)#test_same"] * 2, names(report.ran)
    assert_equal ["(anonymous)#test_same@7", "(anonymous)#test_same@8"], report.ran.map(&:last)
  end

  # #191 review: the `parallel` line goes out when a parallel class starts, so
  # a kill in an anonymous parallel class is not taken for a serial one.
  def test_record_to_marks_an_anonymous_parallel_class
    _code, _marker, report = record_fixture(ANONYMOUS_PARALLEL)
    assert report.parallel
    assert_equal 1, report.killed.size
    refute report.serial_kill
  end

  # #191 review: a result the recorder cannot describe is a lost line, never an
  # exception that would change the verdict.
  def test_a_result_the_recorder_cannot_describe_is_a_lost_line
    io = StringIO.new
    recorder = Mutineer::MinitestIntegration::KillRecorder
    broken = Object.new
    def broken.skipped? = false
    def broken.passed? = raise("no outcome")
    recorder.channel = io
    recorder.send(:send_result, broken)
    report = Mutineer::KillChannel.parse(io.string)
    assert_equal 1, report.lost
    assert_empty report.ran
  ensure
    recorder.channel = nil
  end

  # PR #191 review: a test that runs a parallel class on its own reporter does
  # not start the run's parallel phase, so a later serial failure is serial.
  def test_record_to_ignores_a_nested_run_of_a_parallel_class
    _code, _marker, report = record_fixture(NESTED_PARALLEL)
    assert report.serial_kill
    assert report.parallel
  end

  def test_record_to_and_stop_at_first_failure_cannot_be_combined
    code = fork_status do
      Mutineer::TestRunners::Minitest.run([STOP], stop_at_first_failure: true, record_to: $stderr)
    rescue ArgumentError
      7
    end
    assert_equal 7, code
  end

end
