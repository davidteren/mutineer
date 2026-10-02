# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

# The RSpec runner mirrors the Minitest runner's contract: 0 = all passed,
# 1 = any failure, RSpec's formatter output kept off stdout, and RSpec state
# reset between runs so examples never bleed across successive invocations in
# one process.
#
# Each case forks (mirroring real per-mutant isolation); the child reopens its
# real stdout to a pipe so we can prove the runner kept RSpec's formatter off
# it. Spec output is silenced at the fork boundary, not by the runner (see the
# Isolation.run case below).
class TestRunnersRSpecTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FIX  = File.expand_path("../fixtures/rspec", __dir__)
  PASS = File.join(FIX, "passing_spec.rb")
  FAIL = File.join(FIX, "failing_spec.rb")
  STOP = File.join(FIX, "stop_at_first_failure_spec.rb")
  # Wraps each expectation in to_stdout_from_any_process, which reopens $stdout.
  SUBPROCESS_IO = File.join(FIX, "calculator_subprocess_io_spec.rb")
  NOISY = File.join(FIX, "noisy_spec.rb")
  # Leaves $stdout and $stderr as StringIOs, at load time and inside an example.
  STDOUT_SWAP = File.join(FIX, "calculator_stdout_swap_spec.rb")

  # Returns [exitstatus, captured_real_stdout, captured_real_stderr]. The block
  # runs in the child and returns the integer exit code.
  def in_fork
    rd, wr = IO.pipe
    err_rd, err_wr = IO.pipe
    pid = fork do
      rd.close
      err_rd.close
      $stdout.reopen(wr) # capture anything written to the real fd 1
      $stderr.reopen(err_wr) # and to the real fd 2
      code = yield
      $stdout.flush
      $stderr.flush
      wr.close
      err_wr.close
      exit!(code)
    end
    wr.close
    err_wr.close
    err_reader = Thread.new { err_rd.read }
    out = rd.read
    err = err_reader.value
    rd.close
    err_rd.close
    _, status = Process.waitpid2(pid)
    [status.exitstatus, out, err]
  end

  def test_passing_spec_returns_zero_and_is_silent
    code, out = in_fork { Mutineer::TestRunners::RSpec.run([PASS]) }
    assert_equal 0, code
    assert_empty out.strip, "RSpec output should be silenced, got: #{out.inspect}"
  end

  def test_failing_spec_returns_one
    code, = in_fork { Mutineer::TestRunners::RSpec.run([FAIL]) }
    assert_equal 1, code
  end

  # Runs the stop fixture in a fork. Returns [exit status, marker written?].
  def run_stop_fixture(first, **kwargs)
    Dir.mktmpdir("mutineer-stop") do |dir|
      marker = File.join(dir, "marker")
      code, = in_fork do
        ENV["MUTINEER_FIXTURE_FIRST"] = first
        ENV["MUTINEER_FIXTURE_MARKER"] = marker
        Mutineer::TestRunners::RSpec.run([STOP], **kwargs)
      end
      [code, File.exist?(marker)]
    end
  end

  def test_stop_at_first_failure_skips_the_examples_after_a_failure
    assert_equal [1, false], run_stop_fixture("fail", stop_at_first_failure: true)
  end

  def test_skip_does_not_stop_the_run
    assert_equal [0, true], run_stop_fixture("skip", stop_at_first_failure: true)
  end

  def test_pending_does_not_stop_the_run
    assert_equal [0, true], run_stop_fixture("pending", stop_at_first_failure: true)
  end

  def test_passing_run_is_the_same_with_stop_at_first_failure
    assert_equal [0, true], run_stop_fixture("pass", stop_at_first_failure: true)
  end

  def test_default_runs_every_example_after_a_failure
    assert_equal [1, true], run_stop_fixture("fail")
  end

  def test_spec_that_reopens_stdout_returns_zero_and_is_silent
    code, out = in_fork { Mutineer::TestRunners::RSpec.run([SUBPROCESS_IO]) }
    assert_equal 0, code
    assert_empty out.strip, "RSpec output should be silenced, got: #{out.inspect}"
  end

  # The fork boundary (Isolation.run) silences the spec's stdout. Stderr
  # passes through, because it also carries mutineer's own child diagnostics.
  def test_spec_stdout_is_silenced_at_the_fork_boundary_and_stderr_passes_through
    result = nil
    out, err = capture_subprocess_io do
      result = Mutineer::Isolation.run { Mutineer::TestRunners::RSpec.run([NOISY]) }
    end
    assert_predicate result, :survived?
    refute_includes out, "NOISE-ON-STDOUT"
    assert_includes err, "NOISE-ON-STDERR"
  end

  def test_spec_that_swaps_streams_for_stringios_returns_zero
    code, = in_fork { Mutineer::TestRunners::RSpec.run([STDOUT_SWAP]) }
    assert_equal 0, code
  end

  # Run two different specs sequentially in ONE process; RSpec.reset (inside the
  # runner) must prevent the first run's example from leaking into the second.
  def test_resets_state_between_runs
    _, out = in_fork do
      r1 = Mutineer::TestRunners::RSpec.run([PASS])
      c1 = ::RSpec.world.example_count
      r2 = Mutineer::TestRunners::RSpec.run([FAIL])
      c2 = ::RSpec.world.example_count
      $stdout.puts [r1, c1, r2, c2].join(",")
      0
    end
    r1, c1, r2, c2 = out.strip.split(",").map(&:to_i)
    assert_equal 0, r1, "passing spec should return 0"
    assert_equal 1, c1, "first run should hold exactly its 1 example"
    assert_equal 1, r2, "failing spec should return 1"
    assert_equal 1, c2, "second run must NOT accumulate the first run's example"
  end

  # --- record_to (--matrix) -------------------------------------------------
  # A matrix run never stops: every example runs, and each outcome goes to the
  # KillChannel pipe between a `start` and an `end` line. A test is its spec
  # file, its full description and its example id.

  # Runs `spec` with a channel, from `dir` when given (to pick up a project
  # .rspec), with `env` set in the child. Returns [exit status, marker written?, report].
  def record_spec(first, spec: STOP, dir: nil, env: {})
    rd, wr = IO.pipe
    Dir.mktmpdir("mutineer-record") do |tmp|
      marker = File.join(tmp, "marker")
      code, = in_fork do
        rd.close
        Dir.chdir(dir) if dir
        env.each { |k, v| ENV[k] = v }
        ENV["MUTINEER_FIXTURE_FIRST"] = first
        ENV["MUTINEER_FIXTURE_MARKER"] = marker
        Mutineer::TestRunners::RSpec.run([spec], record_to: wr)
      end
      wr.close
      [code, File.exist?(marker), Mutineer::KillChannel.parse(rd.read)]
    end
  ensure
    [rd, wr].each { |io| io.close unless io.closed? }
  end

  FIRST  = "stop at first failure fixture runs first"
  MARKER = "stop at first failure fixture writes the marker"
  FIRST_TEST  = [STOP, FIRST, "./test/fixtures/rspec/stop_at_first_failure_spec.rb[1:1]"].freeze
  MARKER_TEST = [STOP, MARKER, "./test/fixtures/rspec/stop_at_first_failure_spec.rb[1:2]"].freeze

  def names(tests) = tests.map { |_file, name, _id| name }

  def assert_full_run(code, marker, report)
    assert_equal [1, true], [code, marker]
    assert_equal [FIRST], names(report.killed)
    assert report.started, "a full run sends start"
    assert report.finished, "a full run sends end"
  end

  def test_record_to_runs_every_example_and_names_the_failure
    code, marker, report = record_spec("fail", dir: ROOT)
    assert_full_run(code, marker, report)
    assert_equal [FIRST_TEST], report.killed
    assert_equal [FIRST_TEST, MARKER_TEST], report.ran
    refute report.parallel
    assert_equal 0, report.lost
  end

  def test_record_to_sends_nothing_for_a_pending_example
    code, _, report = record_spec("pending")
    assert_equal 0, code
    assert_empty report.killed
    assert_equal [MARKER], names(report.ran)
  end

  def test_record_to_runs_every_example_when_the_project_rspec_sets_fail_fast
    Dir.mktmpdir("mutineer-dotrspec") do |dir|
      File.write(File.join(dir, ".rspec"), "--fail-fast\n")
      assert_full_run(*record_spec("fail", dir: dir))
    end
  end

  # RSpec reads SPEC_OPTS after the command line, so a --fail-fast there beat
  # a --no-fail-fast argument.
  def test_record_to_runs_every_example_when_spec_opts_sets_fail_fast
    assert_full_run(*record_spec("fail", env: { "SPEC_OPTS" => "--fail-fast" }))
  end

  # A spec helper loaded through .rspec sets fail_fast on the configuration.
  def test_record_to_runs_every_example_when_a_spec_helper_sets_fail_fast
    Dir.mktmpdir("mutineer-helper") do |dir|
      FileUtils.mkdir_p(File.join(dir, "spec"))
      File.write(File.join(dir, "spec", "fail_fast_helper.rb"), "RSpec.configure { |c| c.fail_fast = true }\n")
      File.write(File.join(dir, ".rspec"), "--require fail_fast_helper\n")
      assert_full_run(*record_spec("fail", dir: dir))
    end
  end

  def test_record_to_restores_spec_opts
    _, out = in_fork do
      ENV["SPEC_OPTS"] = "--no-color"
      Mutineer::TestRunners::RSpec.run([PASS], record_to: $stderr.dup)
      $stdout.puts ENV.fetch("SPEC_OPTS", "unset")
      0
    end
    assert_equal "--no-color", out.strip
  end

  # An example that forks and runs a failing suite in the child inherits the
  # configured formatter and the channel; only the process that created the
  # formatter may write.
  def test_record_to_ignores_examples_run_in_a_forked_process
    Dir.mktmpdir("mutineer-forked") do |dir|
      spec = File.join(dir, "forking_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.describe "forking" do
          it "runs a failing example in a forked child" do
            pid = fork do
              RSpec.describe("inner") { it("fails") { expect(1).to eq(2) } }.run(RSpec.configuration.reporter)
              exit!(0)
            end
            Process.wait(pid)
          end
        end
      RUBY
      code, _, report = record_spec("pass", spec: spec)
      assert_equal 0, code
      assert_empty report.killed
      assert_equal ["forking runs a failing example in a forked child"], names(report.ran)
    end
  end

  def test_record_to_tells_apart_examples_that_share_a_description
    Dir.mktmpdir("mutineer-dup") do |dir|
      spec = File.join(dir, "dup_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.describe "dup" do
          it("checks") { expect(1).to eq(1) }
          it("checks") { expect(1).to eq(2) }
        end
      RUBY
      code, _, report = record_spec("pass", spec: spec, dir: dir)
      assert_equal 1, code
      assert_equal [[spec, "dup checks"]] * 2, report.ran.map { |file, name, _id| [file, name] }
      ids = report.ran.map(&:last)
      assert_equal ["[1:1]", "[1:2]"], ids.map { |id| id[/\[[\d:]+\]\z/] }
      assert_equal [ids.last], report.killed.map(&:last)
    end
  end

  def test_record_to_and_stop_at_first_failure_cannot_be_combined
    code, = in_fork do
      Mutineer::TestRunners::RSpec.run([STOP], stop_at_first_failure: true, record_to: $stderr)
    rescue ArgumentError
      7
    end
    assert_equal 7, code
  end

end
