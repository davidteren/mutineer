# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"

# #26/#27 Phase 2a (U2 + U3): the tool-side DaemonClient spawns the app-side daemon
# under the fixture app's bundle, boots it once, and gets structured verdicts. Real
# end-to-end (fork + Rails boot), so a handful of requests share one booted daemon.
class DaemonClientTest < Minitest::Test
  APP  = File.expand_path("fixtures/rails_app", __dir__)
  SRC  = File.join(APP, "app/models/order.rb")
  TEST = File.join(APP, "test/models/order_test.rb")
  ORIGINAL = File.read(SRC)

  def boot_config
    {
      project_root: APP,
      boot: File.join(APP, "config/environment"),
      load_paths: [File.join(APP, "test")],
      source_dirs: [File.join(APP, "app/models")], # so timeout orphans get swept
      framework: "minitest",
      rails: true
    }
  end

  def with_client
    client = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).start
    yield client
  ensure
    client&.quit
  end

  def run_payload(client, id, code, timeout: 30)
    client.request(id: id, payload: { "code" => code, "source_file" => SRC },
                   tests: [TEST], timeout: timeout)
  end

  # One booted daemon, several mutants — the boot-once + structured-verdict contract.
  def test_daemon_reports_structured_verdicts
    with_client do |client|
      # Original source, no mutation → strong suite passes → SURVIVED.
      assert_equal "survived", run_payload(client, 1, ORIGINAL)

      # A real mutation the strong suite catches → KILLED.
      killed = ORIGINAL.sub("quantity * unit_price_cents", "quantity + unit_price_cents")
      refute_equal ORIGINAL, killed, "mutation anchor must exist"
      assert_equal "killed", run_payload(client, 2, killed)

      # Payload that raises on load (references an undefined constant) → ERROR,
      # distinct from killed — the structured-verdict win for failures around the test.
      assert_equal "error", run_payload(client, 3, "NoSuchConstantXYZ.definitely_missing")

      # Back to a clean mutant → SURVIVED again (daemon reused, not wedged by the error).
      assert_equal "survived", run_payload(client, 4, ORIGINAL)
    end
  end

  # A payload that hangs on load is SIGKILLed at the deadline → timeout (fast).
  def test_hung_payload_times_out_and_daemon_recovers
    with_client do |client|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal "timeout", run_payload(client, 1, "sleep 999", timeout: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 10, "should kill near the 1s deadline"

      # Daemon serves the next request normally — the loop was not wedged.
      assert_equal "survived", run_payload(client, 2, ORIGINAL)
    end
  end

  # #102: a boot file that prints to stdout must not break the JSON handshake.
  # Every route to fd 1 lands on stderr; mutants still run afterwards.
  def test_boot_stdout_goes_to_stderr_not_the_protocol
    Dir.mktmpdir("daemon-noisy-boot-") do |dir|
      boot = File.join(dir, "noisy_boot.rb")
      File.write(boot, <<~RUBY)
        require #{File.join(APP, "config/environment").inspect}
        puts "noisy puts"
        STDOUT.puts "noisy STDOUT"
        $stdout.puts "noisy $stdout"
        IO.for_fd(1, autoclose: false).syswrite("noisy fd1\\n")
        system("echo noisy subprocess")
      RUBY
      errio = StringIO.new
      client = Mutineer::DaemonClient.new(boot: boot_config.merge(boot: boot), app_root: APP, errio: errio).start
      begin
        assert_equal "survived", run_payload(client, 1, ORIGINAL)
        killed = ORIGINAL.sub("quantity * unit_price_cents", "quantity + unit_price_cents")
        assert_equal "killed", run_payload(client, 2, killed)
        expected = ["noisy puts", "noisy STDOUT", "noisy $stdout", "noisy fd1", "noisy subprocess"]
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until expected.all? { |line| errio.string.include?(line) } ||
              Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          Thread.pass
        end
        expected.each { |line| assert_includes errio.string, line }
      ensure
        client.quit
      end
    end
  end

  # #102: a mutant fork must not hold the protocol channel open. If the daemon
  # dies while a child still runs, the client sees EOF at once and scores
  # `error`, rather than waiting for the orphaned child to finish.
  def test_daemon_crash_is_seen_while_a_child_still_runs
    Dir.mktmpdir("daemon-crash-") do |dir|
      marker = File.join(dir, "child.pid")
      # exit! so a surviving child never goes on to run tests on a shared DB.
      payload = "File.write(#{marker.inspect}, Process.pid.to_s); sleep 15; exit!(0)"
      with_client do |client|
        reply = Thread.new { run_payload(client, 1, payload, timeout: 60) } # rubocop:disable ThreadSafety/NewThread
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        sleep 0.05 until File.size?(marker) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        assert File.size?(marker), "the daemon never forked the mutant child"

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Process.kill(:KILL, client.instance_variable_get(:@wait_thr).pid)
        assert_equal "error", reply.value
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 10, "the orphaned child must not hold the protocol pipe"
      ensure
        Process.kill(:KILL, File.read(marker).to_i) rescue nil # rubocop:disable Style/RescueModifier
      end
    end
  end

  # A bad boot path surfaces as a clean DaemonBootError, not a hang.
  def test_bad_boot_raises_clean_error
    bad = boot_config.merge(boot: File.join(APP, "config/does_not_exist"))
    assert_raises(Mutineer::DaemonBootError) do
      Mutineer::DaemonClient.new(boot: bad, app_root: APP).start
    end
  end
end
