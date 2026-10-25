# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"
require "open3"

# #26/U5 — per-worker DB routing, proven end-to-end against the bundled fixture app.
# Drives the daemon directly (via DaemonClient) so it can exercise MORE THAN ONE
# worker slot serially: for each of worker 0 and worker 1, the unmutated source
# SURVIVES and an arithmetic mutant is KILLED. That proves after_fork(worker) connects
# each isolated `storage/test-<worker>.sqlite3`, loads its schema, and lets the
# transactional fixtures repopulate it — the serial-correctness half of #26 (the
# concurrent `--jobs N == --jobs 1` gate is U6).
class DaemonWorkerDbTest < Minitest::Test
  APP   = File.expand_path("fixtures/rails_app", __dir__)
  ORDER = File.join(APP, "app/models/order.rb")
  TEST  = File.join(APP, "test/models/order_test.rb")

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
end
