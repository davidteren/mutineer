# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"
require "mutineer/rails_worker_db"
require "mutineer/runner"
require "mutineer/cli"
require "open3"
require "tmpdir"

# Postgres worker databases. Skipped unless DB=postgres. The CI job sets that
# and provides Postgres 16. These tests use the fixture app's pg client.
class DaemonPostgresTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)
  ROOT = File.expand_path("..", __dir__)
  ORDER = File.join(APP, "app/models/order.rb")
  TEST_FILE = File.join(APP, "test/models/order_test.rb")
  WORKER_DB = File.expand_path("../lib/mutineer/rails_worker_db.rb", __dir__)
  BASE = ENV.fetch("PGDATABASE", "mutineer_rails_test")

  def setup
    skip "set DB=postgres to run Postgres worker-database tests" unless ENV["DB"] == "postgres"
  end

  def config_for(jobs)
    Mutineer::Config.new(
      sources: [ORDER], tests: [TEST_FILE], project_root: APP, boot: "config/environment",
      rails: true, daemon: true, strategy: "reload", framework: "minitest", jobs: jobs
    )
  end

  def boot_config(slots: 2, role: nil, cache_dir: nil)
    boot = {
      project_root: APP,
      boot: File.join(APP, "config/environment"),
      load_paths: [File.join(APP, "test")],
      source_dirs: [File.join(APP, "app/models")],
      framework: "minitest",
      rails: true,
      schema: File.join(APP, "db/schema.rb"),
      require_paths: [File.join(APP, "test/support/seed_setup")],
      slots: slots
    }
    boot[:db_role] = role if role
    boot[:cache_dir] = cache_dir if cache_dir
    boot
  end

  def app_env
    Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
  end

  def fixture_ruby(script, extra_env: {}, args: [])
    Open3.capture2e(app_env.merge(extra_env), "bundle", "exec", "ruby", "-e", script, *args,
                    chdir: APP, unsetenv_others: true)
  end

  def statuses(aggregate)
    aggregate.results.map { |result| [result.id, result.status] }.sort
  end

  def test_four_slots_copy_the_base_rows
    client = Mutineer::DaemonClient.new(boot: boot_config(slots: 4), app_root: APP).start
    client.quit
    names = 4.times.map { |slot| Mutineer::RailsWorkerDb.postgres_worker_database(BASE, slot) }
    script = <<~RUBY
      require "pg"
      #{names.inspect}.each do |name|
        conn = PG.connect(#{pg_connect_literal("dbname: name")})
        count = conn.exec("SELECT COUNT(*) FROM seeded_rows").getvalue(0, 0)
        puts "\#{name}=\#{count}"
      end
    RUBY
    out, status = fixture_ruby(script)
    assert status.success?, out
    names.each { |name| assert_includes out, "#{name}=1" }
  end

  def test_provision_runs_again_when_coverage_is_cached
    Dir.mktmpdir("mutineer-pg-cache") do |dir|
      config = config_for(1)
      config.cache_dir = dir
      capture_subprocess_io { Mutineer::Runner.execute(config) }
      aggregate = nil
      _out, err = capture_subprocess_io { aggregate = Mutineer::Runner.execute(config).first }
      assert_equal 100.0, aggregate.mutation_score
      assert_includes err, "provisioned 1 postgres worker database(s) from #{BASE}"
    end
  end

  def test_jobs_8_matches_jobs_1
    serial = nil
    parallel = nil
    capture_subprocess_io do
      serial = Mutineer::Runner.execute(config_for(1)).first
      parallel = Mutineer::Runner.execute(config_for(8)).first
    end
    assert_equal statuses(serial), statuses(parallel)
    assert_equal 100.0, parallel.mutation_score
    assert_operator parallel.killed_count, :>, 0
  end

  def test_a_restarted_worker_reconnects_without_provisioning_again
    client = nil
    primer = Mutineer::DaemonClient.new(boot: boot_config(slots: 1), app_root: APP).start
    primer.quit
    client = Mutineer::DaemonClient.new(boot: boot_config(slots: 1, role: "worker"), app_root: APP).start
    pid = client.instance_variable_get(:@wait_thr).pid
    Process.kill("KILL", pid)
    code = File.read(ORDER)
    assert_equal "error", request(client, 1, code)
    assert_equal "survived", request(client, 2, code)
  ensure
    client&.quit
  end

  def test_an_open_session_on_the_base_stops_before_mutants
    holder = spawn_holder(<<~RUBY)
      require "pg"
      PG.connect(#{pg_connect_literal("dbname: #{BASE.inspect}")})
      $stdout.puts "HELD"
      $stdout.flush
      sleep 180
    RUBY
    out, status = run_cli(1)
    assert_equal 1, status.exitstatus, out
    assert_includes out, BASE
    assert_match(/being accessed|other users|could not provision/i, out)
    refute_match(/mutation score/i, out)
  ensure
    stop_holder(holder)
  end

  def test_a_role_without_createdb_stops_and_names_the_permission
    out, status = fixture_ruby(<<~RUBY)
      require "pg"
      conn = PG.connect(#{pg_connect_literal("dbname: #{BASE.inspect}")})
      if conn.exec("SELECT 1 FROM pg_roles WHERE rolname = 'mutineer_no_createdb'").ntuples.positive?
        conn.exec("DROP OWNED BY mutineer_no_createdb CASCADE")
        conn.exec("DROP ROLE mutineer_no_createdb")
      end
      conn.exec("CREATE ROLE mutineer_no_createdb LOGIN NOSUPERUSER NOCREATEDB PASSWORD 'mutineer_no_createdb'")
      conn.exec("GRANT CONNECT ON DATABASE postgres TO mutineer_no_createdb")
      conn.exec("GRANT CONNECT ON DATABASE #{BASE} TO mutineer_no_createdb")
      conn.exec("GRANT USAGE, CREATE ON SCHEMA public TO mutineer_no_createdb")
      conn.exec("DROP TABLE IF EXISTS seeded_rows")
      # A leftover slot belongs to the superuser. Drop it first so this run
      # fails on CREATE DATABASE, which is the missing CREATEDB permission.
      #{(0..7).map { |slot| Mutineer::RailsWorkerDb.postgres_worker_database(BASE, slot) }.inspect}.each do |name|
        quoted = '"' + name.gsub('"', '""') + '"'
        conn.exec("DROP DATABASE IF EXISTS " + quoted)
      end
      conn.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO mutineer_no_createdb")
    RUBY
    assert status.success?, out

    out, status = run_cli(1, "PGUSER" => "mutineer_no_createdb", "PGPASSWORD" => "mutineer_no_createdb")
    assert_equal 1, status.exitstatus, out
    assert_match(/permission denied/i, out)
    assert_includes out, BASE
  ensure
    fixture_ruby(<<~RUBY)
      require "pg"
      conn = PG.connect(#{pg_connect_literal("dbname: #{BASE.inspect}")})
      if conn.exec("SELECT 1 FROM pg_roles WHERE rolname = 'mutineer_no_createdb'").ntuples.positive?
        conn.exec("DROP OWNED BY mutineer_no_createdb CASCADE")
        conn.exec("DROP ROLE mutineer_no_createdb")
      end
    RUBY
  end

  def test_a_second_run_stops_while_the_first_holds_the_lock
    holder = spawn_holder(<<~RUBY)
      require "./config/environment"
      require #{WORKER_DB.inspect}
      Mutineer::RailsWorkerDb.prepare_worker!
      $stdout.puts "READY"
      $stdout.flush
      sleep 180
    RUBY
    out, status = run_cli(1)
    assert_equal 1, status.exitstatus, out
    assert_includes out, "another Mutineer run is using #{BASE}"
  ensure
    stop_holder(holder)
  end

  def test_a_killed_run_does_not_block_the_next_run
    holder = spawn_holder(<<~RUBY)
      require "./config/environment"
      require #{WORKER_DB.inspect}
      Mutineer::RailsWorkerDb.provision(2)
      $stdout.puts "READY"
      $stdout.flush
      sleep 180
    RUBY
    stop_holder(holder, signal: "KILL")
    holder = nil
    aggregate = nil
    capture_subprocess_io { aggregate = Mutineer::Runner.execute(config_for(1)).first }
    assert_equal 100.0, aggregate.mutation_score
  ensure
    stop_holder(holder)
  end

  private

  def request(client, id, code)
    client.request(id: id, worker: 0, timeout: 60,
                   payload: { "code" => code, "source_file" => ORDER }, tests: [TEST_FILE])
  end

  # Keyword arguments for PG.connect, from the current environment.
  def pg_connect_literal(extra)
    parts = [extra]
    parts << "host: #{ENV['PGHOST'].inspect}" if ENV["PGHOST"] && !ENV["PGHOST"].empty?
    parts << "port: #{ENV['PGPORT'].inspect}" if ENV["PGPORT"] && !ENV["PGPORT"].empty?
    parts << "user: #{ENV['PGUSER'].inspect}" if ENV["PGUSER"] && !ENV["PGUSER"].empty?
    parts << "password: #{ENV['PGPASSWORD'].inspect}" if ENV["PGPASSWORD"] && !ENV["PGPASSWORD"].empty?
    parts.join(", ")
  end

  def spawn_holder(script)
    read, write = IO.pipe
    pid = spawn(app_env, "bundle", "exec", "ruby", "-e", script,
                chdir: APP, unsetenv_others: true, out: write, pgroup: true)
    write.close
    line = read.gets
    read.close
    flunk("holder did not start: #{line.inspect}") unless line&.start_with?("HELD", "READY")
    pid
  end

  def stop_holder(pid, signal: "TERM")
    return unless pid

    Process.kill(signal, -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
    nil
  end

  def run_cli(jobs, extra_env = {})
    script = <<~RUBY
      require "mutineer"
      config = Mutineer::Config.new(
        sources: [#{ORDER.inspect}],
        tests: [#{TEST_FILE.inspect}],
        project_root: #{APP.inspect},
        boot: "config/environment",
        rails: true, daemon: true, strategy: "reload", framework: "minitest", jobs: #{jobs}
      )
      Mutineer::CLI.run(config)
    RUBY
    Open3.capture2e(ENV.to_h.merge(extra_env), "bundle", "exec", "ruby", "-Ilib", "-e", script,
                    chdir: ROOT)
  end
end
