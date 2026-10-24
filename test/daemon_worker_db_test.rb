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
      rails: true,
      schema: File.join(APP, "db/schema.rb")
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

  # Each worker copies every SQLite database, not only the primary. A
  # non-transactional test commits a row to the second database on worker 0.
  # Worker 1 must not see that row: if the workers shared the file, worker 1's
  # test would fail and its mutant would read as a false kill. The base files
  # are removed first, so each copy starts from the extra database's schema file.
  def test_each_worker_copies_the_second_database
    ENV["MUTINEER_SECOND_DB"] = "1"
    ENV["MUTINEER_EXTRA_POOL"] = "1"
    Dir.glob(File.join(APP, "storage", "extra*.sqlite3*")).each { |path| File.delete(path) }
    note = File.join(APP, "test/models/extra_note_test.rb")
    with_client do |client|
      [0, 1].each do |w|
        assert_equal "survived", client.request(id: 40 + w, worker: w, timeout: 60,
                                                payload: { "code" => File.read(ORDER), "source_file" => ORDER },
                                                tests: [note]),
                     "worker #{w}'s copy of the extra database holds no other worker's row"
        assert File.exist?(File.join(APP, "storage", "extra-#{w}.sqlite3")), "worker #{w} has its own extra file"
      end
    end
  ensure
    ENV.delete("MUTINEER_SECOND_DB")
    ENV.delete("MUTINEER_EXTRA_POOL")
  end

  # #222: a seeded worker keeps the copied rows when the base schema is current,
  # and reloads schema.rb (dropping them) when the schema version or the stored
  # schema_sha1 differs, or no schema_sha1 is stored (a plain `load schema.rb`).
  # Runs under the fixture bundle against a temp base DB. The base is a
  # database.yml-style config: Mutineer copies only configured databases.
  SCHEMA_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "digest"
    require "tmpdir"
    ActiveRecord::Migration.verbose = false
    schema = File.expand_path("db/schema.rb")
    Dir.mktmpdir do |dir|
      base = { "test" => { "adapter" => "sqlite3", "database" => File.join(dir, "base.sqlite3") } }
      # New config objects each time: after_fork rewrites them in place.
      connect = lambda do
        ActiveRecord::Base.configurations = base
        ActiveRecord::Base.establish_connection(:test)
      end
      connect.call
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
        connect.call
        c = ActiveRecord::Base.connection
        step.call
        # A fork discards the connections it inherits. This stands in for it.
        ActiveRecord::Base.connection_pool.disconnect!
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

  # A shared database must keep its rows even when its schema is out of date.
  # Schema loading belongs only to the worker copies, never the shared base.
  SHARED_SCHEMA_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "tmpdir"
    ActiveRecord::Migration.verbose = false
    Dir.mktmpdir do |dir|
      shared = File.join(dir, "shared.sqlite3")
      ActiveRecord::Base.configurations = {
        "test" => {
          "primary" => { "adapter" => "sqlite3", "database" => File.join(dir, "primary.sqlite3") },
          "extra" => { "adapter" => "sqlite3", "database" => shared }
        }
      }
      ActiveRecord::Base.establish_connection(:primary)
      load File.expand_path("db/schema.rb")
      SQLite3::Database.new(shared) do |db|
        db.execute("CREATE TABLE extra_notes (id INTEGER PRIMARY KEY, body TEXT)")
        db.execute("INSERT INTO extra_notes (body) VALUES ('keep this row')")
      end
      ActiveRecord::Base.connection_pool.disconnect!
      Mutineer::RailsWorkerDb.after_fork(0, seed: true, shared: %w[extra])
      SQLite3::Database.new(shared) do |db|
        puts "shared_rows=\#{db.get_first_value('SELECT COUNT(*) FROM extra_notes')}"
      end
    end
  RUBY

  def test_a_shared_database_is_not_changed_by_schema_loading
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", SHARED_SCHEMA_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    assert_includes out, "shared_rows=1"
  end

  # A pool from an inline establish_connection hash is not in database.yml, so
  # Mutineer cannot give the worker its own copy. The routing check raises,
  # and the daemon scores the mutant `error`, never a false verdict.
  INLINE_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "tmpdir"
    Dir.mktmpdir do |dir|
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(dir, "inline.sqlite3"))
      Mutineer::RailsWorkerDb.after_fork(0)
      puts "routed"
    rescue RuntimeError => e
      puts e.message
    end
  RUBY

  def test_an_inline_hash_pool_fails_the_routing_check
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", INLINE_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    assert_match(/inline\.sqlite3, which every worker shares/, out)
    refute_includes out, "routed"
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
