# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"
require "mutineer/daemon_server"

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

  def with_client(**options)
    client = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP, **options).start
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

  # #296: an Active Record connection error inside a test is `error`, not
  # `killed`. Any other database error still kills: a mutant can cause bad SQL.
  def test_in_test_database_error_is_error_not_killed
    errio = StringIO.new
    with_client(errio: errio) do |client|
      # Active Record itself raises here: the pool is gone. The fixture app runs
      # Rails 7.2, which raises ConnectionNotEstablished. Rails 8 raises
      # ConnectionNotDefined, which stays `killed`.
      removed_pool = ORIGINAL.sub("quantity * unit_price_cents",
                                  "ActiveRecord::Base.remove_connection; Order.count")
      refute_equal ORIGINAL, removed_pool, "mutation anchor must exist"
      assert_equal "error", run_payload(client, 1, removed_pool)

      raised = ORIGINAL.sub("quantity * unit_price_cents",
                            'raise ActiveRecord::ConnectionNotEstablished, "gone"')
      assert_equal "error", run_payload(client, 2, raised)

      bad_sql = ORIGINAL.sub("quantity * unit_price_cents", 'raise ActiveRecord::StatementInvalid, "bad SQL"')
      assert_equal "killed", run_payload(client, 3, bad_sql)

      assert_equal "survived", run_payload(client, 4, ORIGINAL)
    end
    # The line tells this path apart from a crash, which is also `error`.
    line = "[mutineer-child] a test failed with a database error, so the run has no verdict: " \
           "ActiveRecord::ConnectionNotEstablished: gone."
    assert_includes errio.string, line
    # Both connection-error mutants took this path, the removed pool included.
    assert_equal 2, errio.string.scan("[mutineer-child] a test failed with a database error").size
  end

  # A payload that hangs on load is SIGKILLed at the deadline → timeout (fast).
  def test_hung_payload_times_out_and_daemon_recovers
    with_client do |client|
      temps = -> { Dir.glob(File.join(APP, "app/models", Mutineer::DaemonBackend::DAEMON_TEMP_GLOB)) }
      before = temps.call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal "timeout", run_payload(client, 1, "sleep 999", timeout: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 10, "should kill near the 1s deadline"
      # #250: the SIGKILLed child skipped its own unlink; a file left in
      # app/models breaks the app's next Zeitwerk boot.
      assert_empty temps.call - before, "a timed-out mutant must not leave its file"

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

  # A second boot must start while another process still holds a mutant file
  # in an autoload directory. The sweep leaves that file alone. Its hyphenated
  # name must not stop Zeitwerk.
  def test_a_live_mutant_file_does_not_stop_the_next_boot
    holder = nil
    path = nil
    dead = fork { exit!(0) }
    Process.waitpid(dead)
    path = File.join(APP, "app/models", "mutineer_daemon20200101-#{dead}-live.rb")
    holder = fork do
      File.open(path, "w") do |file|
        file.write("module LiveMutantFile; end\n")
        file.flush
        file.flock(File::LOCK_EX)
        sleep 60
      end
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert File.exist?(path), "the live mutant file was not created"

    with_client do |client|
      assert_equal "survived", run_payload(client, 1, ORIGINAL)
    end
    assert File.exist?(path), "boot must not delete a file another process holds"
  ensure
    if holder
      Process.kill(:KILL, holder) rescue nil # rubocop:disable Style/RescueModifier
      Process.waitpid(holder) rescue nil # rubocop:disable Style/RescueModifier
    end
    File.unlink(path) if path && File.exist?(path)
  end

  # #102: a mutant fork must not hold the protocol channel open. If the daemon
  # dies while a child still runs, the client sees EOF at once and scores
  # `error`, rather than waiting for the orphaned child to finish.
  def test_daemon_crash_is_seen_while_a_child_still_runs
    Dir.mktmpdir("daemon-crash-") do |dir|
      marker = File.join(dir, "child.pid")
      # exit! so a surviving child never goes on to run tests on a shared DB.
      payload = "File.write(#{marker.inspect}, Process.pid.to_s); sleep 60; exit!(0)"
      with_client do |client|
        reply = Thread.new { run_payload(client, 1, payload, timeout: 120) } # rubocop:disable ThreadSafety/NewThread
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        sleep 0.05 until File.size?(marker) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        assert File.size?(marker), "the daemon never forked the mutant child"

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Process.kill(:KILL, client.instance_variable_get(:@wait_thr).pid)
        assert_equal "error", reply.value
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        # Includes the respawn's Rails boot; without the fix this is ~60s.
        assert_operator elapsed, :<, 30, "the orphaned child must not hold the protocol pipe"
      ensure
        child = File.read(marker).to_i if File.size?(marker)
        if child
          Process.kill(:KILL, child) rescue nil # rubocop:disable Style/RescueModifier
          # Killed inside `load`, the child leaves its mutant file in app/models,
          # and a later Rails boot fails on the name (#250).
          Dir.glob(File.join(APP, "app/models", "{.,}mutineer_daemon*-#{child}-*.rb")).each { |f| File.unlink(f) }
        end
      end
    end
  end

  # A caller-supplied output (here STDOUT) is not the daemon's to close. Only the
  # protocol copy that `run` reserved itself is closed in a fork.
  def test_forks_leave_a_caller_supplied_output_open
    pid = fork do
      Mutineer::DaemonServer.instance_variable_set(:@output, STDOUT)
      Mutineer::DaemonServer.send(:close_protocol)
      exit!(STDOUT.closed? ? 1 : 0)
    end
    status = wait_child(pid)
    assert_equal 0, status.exitstatus, "close_protocol closed a caller-supplied STDOUT"
  end

  # A bad boot path surfaces as a clean DaemonBootError, not a hang.
  def test_bad_boot_raises_clean_error
    bad = boot_config.merge(boot: File.join(APP, "config/does_not_exist"))
    assert_raises(Mutineer::DaemonBootError) do
      Mutineer::DaemonClient.new(boot: bad, app_root: APP).start
    end
  end
end
