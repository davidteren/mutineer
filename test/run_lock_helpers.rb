# frozen_string_literal: true

# Helpers for the run lock tests in the daemon suite (#416). They start a real
# CLI run on the fixture app in its own process group and watch its daemons.
module RunLockHelpers
  # A --require file that slows each test, so a run stays in its mutant phase
  # long enough to probe its lock or kill a daemon.
  def write_hold_file(dir)
    path = File.join(dir, "hold.rb")
    File.write(path, <<~RUBY)
      require "minitest"
      module MutineerHoldOpen
        def before_setup
          sleep 0.5
          super
        end
      end
      Minitest::Test.prepend(MutineerHoldOpen)
    RUBY
    path
  end

  # A --require file that appends "<pid> <db_role>" to `log` in each daemon
  # that loads it. The daemon loads --require files before its database setup.
  def write_role_file(dir, log)
    path = File.join(dir, "role.rb")
    File.write(path, <<~RUBY)
      cfg = Mutineer::DaemonServer.instance_variable_get(:@cfg) || {}
      File.open(#{log.inspect}, "a") { |f| f.puts("\#{Process.pid} \#{cfg["db_role"]}") }
    RUBY
    path
  end

  # The pids that `write_role_file` logged for `role`, in boot order.
  def daemon_pids(log, role)
    return [] unless File.exist?(log)

    File.readlines(log, chomp: true).filter_map do |line|
      pid, logged_role = line.split(" ", 2)
      Integer(pid) if logged_role == role
    end
  end

  # Wait for the run's first mutant progress line. By then every daemon the
  # run needs has booted and taken its lock. False when the run ended first.
  def wait_for_mutant_phase(pid, log, timeout: 90)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      return false unless process_alive?(pid)
      return true if File.exist?(log) && File.read(log).match?(%r{\d+/\d+ mutants})

      sleep 0.05
    end
    false
  end

  # The tool's environment for a fixture run, without the settings that would
  # point the fixture app at another database than the test chose.
  def fixture_run_env(extra = {})
    ENV.to_h.merge("DATABASE_URL" => nil, "MUTINEER_SECOND_DB" => nil).merge(extra)
  end
end
