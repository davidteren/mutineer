# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"
require "mutineer/cli"
require "mutineer/runner"
require "json"
require "open3"
require "tmpdir"

# #26/U5 — per-worker DB routing, proven end-to-end against the bundled fixture app.
# Drives the daemon directly (via DaemonClient) so it can exercise MORE THAN ONE
# worker slot serially: for each of worker 0 and worker 1, the unmutated source
# SURVIVES and an arithmetic mutant is KILLED. That proves after_fork(worker) connects
# each isolated `storage/test-<worker>.sqlite3`, loads its schema, and lets the
# transactional fixtures repopulate it — the serial-correctness half of #26 (the
# concurrent `--jobs N == --jobs 1` gate is U6).
class DaemonWorkerDbTest < Minitest::Test
  APP   = File.expand_path("fixtures/rails_app", __dir__)
  ROOT  = File.expand_path("..", __dir__)
  ORDER = File.join(APP, "app/models/order.rb")
  TEST  = File.join(APP, "test/models/order_test.rb")
  WORKER_DB = File.expand_path("../lib/mutineer/rails_worker_db.rb", __dir__)
  SQLITE_BASE = File.expand_path("storage/test.sqlite3", APP)
  SQLITE_LOCK = "#{SQLITE_BASE}-mutineer.lock"

  def boot_config
    {
      project_root: APP,
      boot: File.join(APP, "config/environment"),
      load_paths: [File.join(APP, "test")],
      source_dirs: [File.join(APP, "app/models")],
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

  def verdict(client, id:, code:, worker:)
    client.request(id: id, worker: worker, timeout: 60,
                   payload: { "code" => code, "source_file" => ORDER },
                   tests: [TEST])
  end

  # #222: every worker slot's DB starts as a copy of the base DB after boot, so a
  # row the --require file wrote is visible, and the clean suite survives, on each.
  def test_each_worker_db_sees_rows_written_while_the_daemon_boots
    boot = boot_config.merge(require_paths: [File.join(APP, "test/support/seed_setup")])
    client = Mutineer::DaemonClient.new(boot: boot, app_root: APP).start
    tax = File.join(APP, "app/models/tax_table.rb")
    [0, 1].each do |w|
      assert_equal "survived",
                   client.request(id: 30 + w, worker: w, timeout: 60,
                                  payload: { "code" => File.read(tax), "source_file" => tax },
                                  tests: [File.join(APP, "test/models/seeded_row_test.rb")]),
                   "worker #{w}'s DB holds the boot-time row"
    end
  ensure
    client&.quit
  end

  # #222: a seeded worker keeps the copied rows when the base schema is current,
  # and reloads schema.rb (dropping them) when the schema version or the stored
  # schema_sha1 differs, or no schema_sha1 is stored (a plain `load schema.rb`).
  # Runs under the fixture bundle against a temp base DB.
  SCHEMA_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "digest"
    require "tmpdir"
    ActiveRecord::Migration.verbose = false
    schema = File.expand_path("db/schema.rb")
    Dir.mktmpdir do |dir|
      base = { adapter: "sqlite3", database: File.join(dir, "base.sqlite3") }
      ActiveRecord::Base.establish_connection(base)
      load schema
      c = ActiveRecord::Base.connection
      c.execute("INSERT INTO orders (created_at, updated_at) VALUES (datetime(), datetime())")
      set_sha = ->(v) { c.execute("INSERT OR REPLACE INTO ar_internal_metadata VALUES ('schema_sha1', \#{c.quote(v)}, datetime(), datetime())") }
      steps = {
        no_sha1: -> {},
        old_version: -> { c.execute("UPDATE schema_migrations SET version = '0'") },
        old_sha1: -> { c.execute("UPDATE schema_migrations SET version = '1'"); set_sha.("stale") },
        same_sha1: -> { set_sha.(Digest::SHA1.hexdigest(File.read(schema))) }
      }
      counts = steps.each_with_index.to_h do |(name, step), worker|
        ActiveRecord::Base.establish_connection(base)
        c = ActiveRecord::Base.connection
        step.call
        Mutineer::RailsWorkerDb.after_fork(worker, schema, seed: true)
        [name, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM orders")]
      end
      puts counts.inspect
    end
  RUBY

  def test_seeded_worker_reloads_the_schema_only_when_it_differs
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", SCHEMA_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    assert_includes out, { no_sha1: 0, old_version: 0, old_sha1: 0, same_sha1: 1 }.inspect
  end

  # #317: a worker loads the schema file the app's config names. A decoy
  # db/schema.rb that SQLite cannot load (like a MySQL schema) sits beside the
  # `schema_dump: schema_sqlite.rb` file whose checksum the base DB holds.
  # Real Rails resolves each name through DaemonServer's worker setup, under the
  # fixture bundle, in a temp db dir. The worker uses the daemon's stored path.
  SCHEMA_DUMP_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/daemon_server", __dir__).inspect}
    require "digest"
    require "tmpdir"
    ActiveRecord::Migration.verbose = false
    daemon = Mutineer::DaemonServer
    daemon.send(:setup_worker_db, "db_role" => "prepare")
    db = Mutineer::RailsWorkerDb
    found = { default: daemon.instance_variable_get(:@schema_path) == File.expand_path("db/schema.rb") }
    Dir.mktmpdir do |dir|
      ActiveRecord::Tasks::DatabaseTasks.db_dir = dir
      File.write(File.join(dir, "schema.rb"), 'raise "loaded the decoy schema.rb"')
      sqlite_schema = File.join(dir, "schema_sqlite.rb")
      File.write(sqlite_schema, File.read("db/schema.rb"))
      base = { adapter: "sqlite3", database: File.join(dir, "base.sqlite3"), schema_dump: "schema_sqlite.rb" }
      route = lambda do |extra = {}|
        ActiveRecord::Base.establish_connection(base.merge(extra))
        daemon.send(:setup_worker_db, "db_role" => "prepare")
        daemon.instance_variable_get(:@schema_path)
      end
      found[:renamed] = route.() == sqlite_schema
      ActiveRecord.schema_format = "ruby"
      config = ActiveRecord::Base.connection_db_config
      found[:rails_string] = ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(config, "ruby") == sqlite_schema
      found[:daemon_string] = route.() == sqlite_schema
      ActiveRecord.schema_format = :ruby
      found[:off] = route.(schema_dump: false)
      ActiveRecord.schema_format = :sql
      found[:sql] = route.()
      ActiveRecord.schema_format = :ruby
      route.()
      load sqlite_schema
      c = ActiveRecord::Base.connection
      c.execute("INSERT INTO orders (created_at, updated_at) VALUES (datetime(), datetime())")
      c.execute("INSERT OR REPLACE INTO ar_internal_metadata VALUES ('schema_sha1', \#{c.quote(Digest::SHA1.hexdigest(File.read(sqlite_schema)))}, datetime(), datetime())")
      db.after_fork(0, daemon.instance_variable_get(:@schema_path), seed: true)
      found[:rows] = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM orders")
      route.()
      found[:decoy] = begin
        db.after_fork(1, File.join(dir, "schema.rb"), seed: true)
      rescue RuntimeError => e
        e.message
      end
    end
    puts found.inspect
  RUBY

  def test_seeded_worker_loads_the_schema_dump_file_not_db_schema_rb
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", SCHEMA_DUMP_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    # The daemon stores the fixture's default or renamed path, including Rails'
    # accepted string format, or nil for schema_dump: false and SQL format.
    # rows: the copy is current against schema_sqlite.rb, so its row stays.
    # decoy: what the old fixed db/schema.rb path did to the same copy.
    assert_includes out, { default: true, renamed: true, rails_string: true, daemon_string: true,
                           off: nil, sql: nil, rows: 1,
                           decoy: "loaded the decoy schema.rb" }.inspect
  end

  def test_verdicts_are_correct_across_distinct_worker_dbs
    original = File.read(ORDER)
    # `*` -> `+`: subtotal 2*1000 becomes 1002, so the strong suite's
    # `assert_equal 2000` fails -> the mutant is killed. Deterministic.
    mutant = original.sub("quantity * unit_price_cents", "quantity + unit_price_cents")
    refute_equal original, mutant, "the substitution must actually change the source"

    with_client do |client|
      [0, 1].each do |w|
        assert_equal "survived", verdict(client, id: 10 + w, code: original, worker: w),
                     "unmutated source survives on worker #{w}'s DB"
        assert_equal "killed", verdict(client, id: 20 + w, code: mutant, worker: w),
                     "arithmetic mutant is killed on worker #{w}'s DB"
      end
    end
  end

  # A holder that already took the shared lock must stop a second CLI run.
  def test_a_second_sqlite_run_stops_while_the_first_holds_the_lock
    skip "SQLite lock tests run only when DB is unset" if ENV["DB"] && !ENV["DB"].empty?

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
    assert_includes out, "another Mutineer run is using #{SQLITE_BASE}"
    refute_includes out, "mutation score"
    refute_includes out, "not green"
    assert File.exist?(SQLITE_LOCK)
    assert system("git", "-C", APP, "check-ignore", "-q", "--", "storage/test.sqlite3-mutineer.lock"),
           "the fixture gitignore does not cover the lock file"
  ensure
    stop_holder(holder)
  end

  # A mutant fork closes its copy of the lock file. The parent's lock stays.
  def test_the_sqlite_lock_survives_a_fork_child_that_frees_its_copy
    skip "SQLite lock tests run only when DB is unset" if ENV["DB"] && !ENV["DB"].empty?

    holder = spawn_holder(<<~RUBY)
      require "./config/environment"
      require #{WORKER_DB.inspect}
      Mutineer::RailsWorkerDb.prepare_worker!
      child = fork do
        Mutineer::RailsWorkerDb.forget_lock_connection_after_fork!
        exit!(0)
      end
      Process.wait(child)
      $stdout.puts "READY"
      $stdout.flush
      sleep 180
    RUBY
    out, status = run_cli(1)
    assert_equal 1, status.exitstatus, out
    assert_includes out, "another Mutineer run is using #{SQLITE_BASE}"
  ensure
    stop_holder(holder)
  end

  # A killed holder releases the lock. The next run takes it again while mutants run.
  def test_a_killed_sqlite_run_does_not_block_the_next_run
    skip "SQLite lock tests run only when DB is unset" if ENV["DB"] && !ENV["DB"].empty?

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
    Dir.mktmpdir do |dir|
      log = File.join(dir, "next.log")
      pid = spawn_logged_run(log, jobs: 1, require_paths: [write_hold_file(dir)])
      seen = run_holds_sqlite_lock?(pid, log)
      status = wait_child(pid, timeout: 180)
      out = File.read(log)
      assert seen, "the next run never held the lock\n#{out}"
      assert_equal 0, status.exitstatus, out
      assert_includes out, "SCORE=100.0"
      refute_includes out, "another Mutineer run"
      assert File.exist?(SQLITE_LOCK)
    end
  ensure
    stop_holder(holder)
  end

  # Two real CLI runs overlap. Run B stops. Run A's verdicts match a solo run.
  def test_overlapping_sqlite_runs_stop_and_keep_the_same_verdicts
    skip "SQLite lock tests run only when DB is unset" if ENV["DB"] && !ENV["DB"].empty?

    Dir.mktmpdir do |dir|
      sleep_file = write_hold_file(dir)
      a_json = File.join(dir, "a.json")
      solo_json = File.join(dir, "solo.json")
      log = File.join(dir, "a.log")
      pid = spawn_logged_run(log, jobs: 1, require_paths: [sleep_file], output: a_json, format: "json")
      seen = run_holds_sqlite_lock?(pid, log)
      assert seen, "run A never held the lock\n#{File.read(log)}"
      out, status = run_cli(1)
      assert_equal 1, status.exitstatus, out
      assert_includes out, "another Mutineer run is using #{SQLITE_BASE}"
      refute_includes out, "not green"
      a_status = wait_child(pid, timeout: 240)
      assert_equal 0, a_status.exitstatus, File.read(log)
      solo_log = File.join(dir, "solo.log")
      solo = spawn_logged_run(solo_log, jobs: 1, require_paths: [sleep_file], output: solo_json, format: "json")
      solo_status = wait_child(solo, timeout: 240)
      assert_equal 0, solo_status.exitstatus, File.read(solo_log)
      assert_equal verdict_pairs(solo_json), verdict_pairs(a_json)
    end
  end

  def spawn_holder(script)
    read, write = IO.pipe
    pid = Process.spawn(app_env, "bundle", "exec", "ruby", "-e", script,
                        chdir: APP, unsetenv_others: true, out: write, pgroup: true)
    write.close
    line = read.gets
    read.close
    return pid if line&.start_with?("READY")

    stop_holder(pid, signal: "KILL")
    flunk("holder did not start: #{line.inspect}")
  end

  def stop_holder(pid, signal: "TERM")
    return unless pid

    Process.kill(signal, -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
    nil
  end

  def run_cli(jobs)
    script = <<~RUBY
      require "mutineer"
      config = Mutineer::Config.new(
        sources: [#{ORDER.inspect}],
        tests: [#{TEST.inspect}],
        project_root: #{APP.inspect},
        boot: "config/environment",
        rails: true, daemon: true, strategy: "reload", framework: "minitest", jobs: #{jobs}
      )
      Mutineer::CLI.run(config)
    RUBY
    Open3.capture2e(ENV.to_h, "bundle", "exec", "ruby", "-Ilib", "-e", script, chdir: ROOT)
  end

  def spawn_logged_run(log, jobs:, require_paths: [], output: nil, format: "human")
    finish = if output
               "Mutineer::CLI.run(config)"
             else
               "aggregate, = Mutineer::Runner.execute(config)\nwarn \"SCORE=\#{aggregate.mutation_score}\""
             end
    script = <<~RUBY
      require "mutineer"
      config = Mutineer::Config.new(
        sources: [#{ORDER.inspect}],
        tests: [#{TEST.inspect}],
        project_root: #{APP.inspect},
        boot: "config/environment",
        rails: true, daemon: true, strategy: "reload", framework: "minitest",
        jobs: #{jobs},
        require_paths: #{require_paths.inspect},
        format: #{format.inspect},
        output: #{output.inspect}
      )
      #{finish}
    RUBY
    Process.spawn(ENV.to_h, "bundle", "exec", "ruby", "-Ilib", "-e", script,
                  chdir: ROOT, out: log, err: log, pgroup: true)
  end

  def app_env
    Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
  end

  # A --require file that slows each test, so a run stays in its mutant phase
  # long enough to probe its lock.
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

  # Wait for the run's first mutant progress line, then probe. By then the run
  # took its lock. An earlier probe holds the exclusive lock for a moment and
  # could make the run's own exclusive request fail.
  def run_holds_sqlite_lock?(pid, log)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      return false unless process_alive?(pid)
      return sqlite_lock_exclusive_busy? if File.exist?(log) && File.read(log).match?(%r{\d+/\d+ mutants})

      sleep 0.05
    end
    false
  end

  # True only when another process holds a conflicting lock.
  # A missing file is not a held lock.
  def sqlite_lock_exclusive_busy?
    _out, status = Open3.capture2(RbConfig.ruby, "-e", <<~RUBY)
      begin
        file = File.open(#{SQLITE_LOCK.inspect}, File::RDONLY)
      rescue Errno::ENOENT
        exit 1
      end
      exit(file.flock(File::LOCK_EX | File::LOCK_NB) ? 0 : 2)
    RUBY
    status.exitstatus == 2
  end

  def verdict_pairs(path)
    doc = JSON.parse(File.read(path))
    rows = []
    %w[survivors no_coverage uncapturable unplaceable ran_at_load ignored].each do |key|
      Array(doc[key]).each { |row| rows << [row["id"], key] }
    end
    Array(doc["no_verdict"]).each { |row| rows << [row["id"], row["status"]] }
    summary = doc.fetch("summary")
    {
      "rows" => rows.sort,
      "killed" => summary["killed"],
      "survived" => summary["survived"],
      "errored" => summary["errored"],
      "timeout" => summary["timeout"],
      "score" => summary["score"],
      "total" => summary["total"]
    }
  end
end
