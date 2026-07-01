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

  # A bad boot path surfaces as a clean DaemonBootError, not a hang.
  def test_bad_boot_raises_clean_error
    bad = boot_config.merge(boot: File.join(APP, "config/does_not_exist"))
    assert_raises(Mutineer::DaemonBootError) do
      Mutineer::DaemonClient.new(boot: bad, app_root: APP).start
    end
  end
end
