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

  # A boot file that fails only in the coverage daemon, so the run falls back
  # to one worker daemon with no prepare daemon (#416, gap 3). Coverage runs
  # in that daemon before its boot file loads, and in no worker daemon.
  def write_coverage_failing_boot(dir, app)
    path = File.join(dir, "fallback_boot.rb")
    File.write(path, <<~RUBY)
      raise "the coverage daemon fails on purpose" if defined?(Coverage) && Coverage.running?

      require #{File.join(app, "config/environment").inspect}
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

  # Start a one-worker daemon run of `source` against `test` in its own process
  # group, with its output in `log`. The run prints SCORE=<score> at the end.
  def spawn_fixture_run(log, app:, source:, test:, boot:, require_paths:)
    script = <<~RUBY
      require "mutineer"
      config = Mutineer::Config.new(
        sources: [#{source.inspect}], tests: [#{test.inspect}], project_root: #{app.inspect},
        boot: #{boot.inspect}, require_paths: #{require_paths.inspect},
        rails: true, daemon: true, strategy: "reload", framework: "minitest", jobs: 1
      )
      aggregate, = Mutineer::Runner.execute(config)
      warn "SCORE=\#{aggregate.mutation_score}"
    RUBY
    Process.spawn(fixture_run_env, "bundle", "exec", "ruby", "-Ilib", "-e", script,
                  chdir: File.expand_path("..", __dir__), out: log, err: log, pgroup: true)
  end

  # The tool's environment for a fixture run, without the settings that would
  # point the fixture app at another database than the test chose.
  def fixture_run_env(extra = {})
    ENV.to_h.merge("DATABASE_URL" => nil, "MUTINEER_SECOND_DB" => nil).merge(extra)
  end
end
