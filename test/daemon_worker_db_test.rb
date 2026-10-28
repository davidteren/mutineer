# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"
require "open3"
require "stringio"
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

  def with_client(errio: $stderr)
    client = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP, errio: errio).start
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
      ActiveRecord::Base.connection.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY)")
      ActiveRecord::Base.connection.execute("INSERT INTO orders DEFAULT VALUES")
      Mutineer::RailsWorkerDb.after_fork(0, File.expand_path("db/schema.rb"), seed: true)
      puts "routed"
    rescue RuntimeError => e
      puts e.message
      puts "inline_rows=\#{ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM orders')}"
    end
  RUBY

  def test_an_inline_hash_pool_fails_the_routing_check
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", INLINE_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    assert_match(/uses an inline SQLite database .*inline\.sqlite3/, out)
    assert_includes out, "inline_rows=1"
    refute_includes out, "routed"
  end

  # A symlinked directory can hide that a worker destination is another test
  # database's base file. Reject it before the backup replaces that base's rows.
  SYMLINK_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "sqlite3"
    require "tmpdir"
    Dir.mktmpdir do |dir|
      real = File.join(dir, "real")
      linked = File.join(dir, "linked")
      Dir.mkdir(real)
      File.symlink(real, linked)
      primary = File.join(real, "test.sqlite3")
      archive = File.join(linked, "test-0.sqlite3")
      { primary => "source row", archive => "keep this row" }.each do |file, body|
        SQLite3::Database.new(file) do |db|
          db.execute("CREATE TABLE markers (body TEXT)")
          db.execute("INSERT INTO markers (body) VALUES (?)", [body])
        end
      end
      ActiveRecord::Base.configurations = {
        "test" => {
          "primary" => { "adapter" => "sqlite3", "database" => primary },
          "archive" => { "adapter" => "sqlite3", "database" => archive }
        }
      }
      begin
        Mutineer::RailsWorkerDb.route_sqlite_configs(0, seed: true, shared: [])
      rescue RuntimeError => e
        puts e.message
      end
      SQLite3::Database.new(archive) do |db|
        puts "archive_row=\#{db.get_first_value('SELECT body FROM markers')}"
      end
    end
  RUBY

  def test_a_symlink_cannot_make_a_worker_copy_overwrite_a_base_database
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", SYMLINK_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    assert_includes out, "is also the base file of a test database"
    assert_includes out, "archive_row=keep this row"
  end

  # Worker destinations can alias each other while both sources are distinct.
  # Every file must keep its rows when routing rejects the collision.
  WORKER_DESTINATION_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "sqlite3"
    require "tmpdir"
    %w[hard_link symlink].each do |kind|
      Dir.mktmpdir do |dir|
        first = File.join(dir, "first.sqlite3")
        second = File.join(dir, "second.sqlite3")
        destination = File.join(dir, "first-0.sqlite3")
        other_destination = File.join(dir, "second-0.sqlite3")
        { first => "first source", second => "second source", destination => "keep worker" }.each do |file, row|
          SQLite3::Database.new(file) do |db|
            db.execute("CREATE TABLE markers (body TEXT)")
            db.execute("INSERT INTO markers (body) VALUES (?)", [row])
          end
        end
        kind == "hard_link" ? File.link(destination, other_destination) : File.symlink(destination, other_destination)
        ActiveRecord::Base.configurations = {
          "test" => {
            "primary" => { "adapter" => "sqlite3", "database" => first },
            "extra" => { "adapter" => "sqlite3", "database" => second }
          }
        }
        begin
          Mutineer::RailsWorkerDb.route_sqlite_configs(0, seed: true, shared: [])
          puts "unexpected copy"
        rescue RuntimeError => e
          puts e.message
        end
        [first, second, destination, other_destination].each do |file|
          SQLite3::Database.new(file) { |db| puts "\#{kind}_row=\#{db.get_first_value('SELECT body FROM markers')}" }
        end
        puts "\#{kind}_configs_unchanged=\#{Mutineer::RailsWorkerDb.test_configs.map(&:database) == [first, second]}"
      end
    end
  RUBY

  def test_worker_destination_aliases_fail_before_any_database_copy
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", WORKER_DESTINATION_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    refute_includes out, "unexpected copy"
    %w[hard_link symlink].each do |kind|
      assert_includes out, "#{kind}_row=first source"
      assert_includes out, "#{kind}_row=second source"
      assert_equal 2, out.lines.count { |line| line.strip == "#{kind}_row=keep worker" }
      assert_includes out, "#{kind}_configs_unchanged=true"
    end
  end

  # A config on the primary's file uses its schema, even when the alias has
  # a different schema dump. An independent extra file still loads its schema.
  PRIMARY_ALIAS_SCHEMA_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "sqlite3"
    require "tmpdir"
    ActiveRecord::Migration.verbose = false
    %w[alias independent].each do |kind|
      Dir.mktmpdir do |dir|
        primary = File.join(dir, "primary.sqlite3")
        extra = File.join(dir, "extra.sqlite3")
        schema = File.join(dir, "extra_schema.rb")
        ActiveRecord::Tasks::DatabaseTasks.db_dir = dir
        File.write(schema, "ActiveRecord::Schema.define(version: 2) { create_table(:orders, force: true) { |t| t.string :body } }")
        files = kind == "alias" ? [primary] : [primary, extra]
        files.each do |file|
          SQLite3::Database.new(file) do |db|
            db.execute("CREATE TABLE orders (body TEXT)")
            db.execute("INSERT INTO orders VALUES ('boot row')")
          end
        end
        File.symlink(primary, extra) if kind == "alias"
        ActiveRecord::Base.configurations = {
          "test" => {
            "primary" => { "adapter" => "sqlite3", "database" => primary },
            "extra" => { "adapter" => "sqlite3", "database" => extra, "schema_dump" => "extra_schema.rb" }
          }
        }
        ActiveRecord::Base.establish_connection(:primary)
        ActiveRecord::Base.connection_pool.disconnect!
        Mutineer::RailsWorkerDb.after_fork(0, seed: true)
        extra_config = Mutineer::RailsWorkerDb.test_configs.find { |config| config.name == "extra" }
        SQLite3::Database.new(extra_config.database) do |db|
          puts "\#{kind}_rows=\#{db.get_first_value('SELECT COUNT(*) FROM orders')}"
        end
      end
    end
  RUBY

  def test_a_primary_file_alias_keeps_the_primary_schema_and_boot_rows
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", PRIMARY_ALIAS_SCHEMA_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    assert_includes out, "alias_rows=1"
    assert_includes out, "independent_rows=0"
  end

  # Conflicting schemas for one secondary file must fail before either loads.
  # Both config orders preserve copied rows; identical dumps remain supported.
  SECONDARY_ALIAS_SCHEMA_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "tmpdir"
    require "sqlite3"
    ActiveRecord::Migration.verbose = false
    %w[conflicting reversed matching].each do |kind|
      Dir.mktmpdir do |dir|
        primary = File.join(dir, "primary.sqlite3")
        archive = File.join(dir, "archive.sqlite3")
        other = File.join(dir, "alias.sqlite3")
        dump = "ActiveRecord::Schema.define(version: 2) { create_table(:orders, force: true) { |t| t.string :body } }"
        File.write(File.join(dir, "archive_schema.rb"), dump)
        File.write(File.join(dir, "alias_schema.rb"), kind == "matching" ? dump : dump.sub("version: 2", "version: 3"))
        SQLite3::Database.new(primary) { |db| db.execute("CREATE TABLE markers (body TEXT)") }
        ActiveRecord::Base.configurations = {"test" => {
          "primary" => {"adapter" => "sqlite3", "database" => primary},
          "archive" => {"adapter" => "sqlite3", "database" => archive, "schema_dump" => "archive_schema.rb"},
          "alias" => {"adapter" => "sqlite3", "database" => other, "schema_dump" => "alias_schema.rb"}
        }}
        if kind == "reversed"
          configs = ActiveRecord::Base.configurations.configs_for(env_name: "test")
          ActiveRecord::Base.configurations = configs.reverse
        end
        ActiveRecord::Tasks::DatabaseTasks.db_dir = dir
        archive_config = Mutineer::RailsWorkerDb.test_configs.find { |c| c.name == "archive" }
        ActiveRecord::Base.establish_connection(:archive)
        ActiveRecord::Tasks::DatabaseTasks.load_schema(archive_config)
        SQLite3::Database.new(archive) { |db| db.execute("INSERT INTO orders VALUES (1, 'keep boot row')") }
        File.symlink(archive, other)
        ActiveRecord::Base.establish_connection(:primary)
        ActiveRecord::Base.connection_handler.connection_pool_list.each(&:disconnect!)
        begin
          Mutineer::RailsWorkerDb.after_fork(0, seed: true)
        rescue RuntimeError => e
          puts "\#{kind}_error=\#{e.message}"
        end
        copied = Mutineer::RailsWorkerDb.test_configs.find { |c| c.name == "archive" }.database
        SQLite3::Database.new(copied) { |db| puts "\#{kind}_rows=\#{db.get_first_value('SELECT COUNT(*) FROM orders')}" }
      end
    end
  RUBY

  def test_secondary_file_aliases_do_not_reload_another_schema_over_boot_rows
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", SECONDARY_ALIAS_SCHEMA_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    %w[conflicting reversed matching].each { |kind| assert_includes out, "#{kind}_rows=1" }
    assert_match(/conflicting_error=.*conflicting schema dumps/, out)
    assert_match(/reversed_error=.*conflicting schema dumps/, out)
    refute_includes out, "matching_error="
  end

  # Exercise the Rails 7.0 version and helper seams in an isolated process
  # with real ActiveRecord pools and SQLite rows. Extra files stay on their
  # base path so no empty copy needs an unavailable per-config schema loader.
  LEGACY_ROUTING_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "sqlite3"
    require "tmpdir"
    ActiveRecord.define_singleton_method(:version) { Gem::Version.new("7.0.8") }
    tasks = ActiveRecord::Tasks::DatabaseTasks
    %i[with_temporary_pool_for_each with_temporary_connection_for_each].each do |helper|
      tasks.singleton_class.send(:undef_method, helper) if tasks.respond_to?(helper)
    end
    Dir.mktmpdir do |dir|
      primary = File.join(dir, "primary.sqlite3")
      extra = File.join(dir, "extra.sqlite3")
      missing = File.join(dir, "missing.sqlite3")
      [primary, extra].each do |file|
        SQLite3::Database.new(file) do |db|
          db.execute("CREATE TABLE markers (body TEXT)")
          db.execute("INSERT INTO markers VALUES ('boot row')")
        end
      end
      ActiveRecord::Base.configurations = {
        "test" => {
          "primary" => { "adapter" => "sqlite3", "database" => primary },
          "alias" => { "adapter" => "sqlite3", "database" => primary },
          "extra" => { "adapter" => "sqlite3", "database" => extra },
          "missing" => { "adapter" => "sqlite3", "database" => missing }
        }
      }
      ActiveRecord::Base.establish_connection(:primary)
      Class.new(ActiveRecord::Base) do
        def self.name = "LegacyExtraRecord"
        self.abstract_class = true
        establish_connection(:extra)
      end
      ActiveRecord::Base.connection_handler.connection_pool_list.each(&:disconnect!)
      puts "metadata_copied=\#{Mutineer::RailsWorkerDb.database_names.fetch('copied').join(',')}"
      Mutineer::RailsWorkerDb.after_fork(0, seed: true)
      configs = Mutineer::RailsWorkerDb.test_configs.to_h { |config| [config.name, config.database] }
      puts "primary_copied=\#{configs.fetch('primary') == File.join(dir, 'primary-0.sqlite3')}"
      puts "alias_copied=\#{configs.fetch('alias') == configs.fetch('primary')}"
      puts "extra_kept=\#{configs.fetch('extra') == extra}"
      puts "missing_kept=\#{configs.fetch('missing') == missing && !File.exist?(File.join(dir, 'missing-0.sqlite3'))}"
      puts "extra_copy_absent=\#{!File.exist?(File.join(dir, 'extra-0.sqlite3'))}"
      puts "primary_rows=\#{ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM markers')}"
      Mutineer::RailsWorkerDb.recheck_routing!
    end
  RUBY

  def test_rails_70_routes_only_the_primary_file_group
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", LEGACY_ROUTING_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    assert_includes out, "metadata_copied=primary"
    %w[primary_copied alias_copied extra_kept missing_kept extra_copy_absent].each do |check|
      assert_includes out, "#{check}=true"
    end
    assert_includes out, "primary_rows=1"
  end

  # The check after tests must catch an inline pool opened by the test file,
  # after the worker's initial routing check has already passed.
  def test_an_inline_pool_opened_during_tests_scores_error
    assert_late_inline_pool_error
  end

  def test_an_inline_uri_pool_opened_during_tests_scores_error
    assert_late_inline_pool_error(uri: true)
  end

  def assert_late_inline_pool_error(uri: false)
    Dir.mktmpdir do |dir|
      test = File.join(dir, "late_inline_test.rb")
      database = File.join(dir, "inline.sqlite3")
      database = "file:#{database}" if uri
      flags = uri ? ", flags: SQLite3::Constants::Open::READWRITE | SQLite3::Constants::Open::CREATE | SQLite3::Constants::Open::URI" : ""
      File.write(test, <<~RUBY)
        require #{File.join(APP, "test/test_helper.rb").inspect}
        require "sqlite3"
        class LateInlineRecord < ActiveRecord::Base
          self.abstract_class = true
          establish_connection(adapter: "sqlite3", database: #{database.inspect}#{flags})
        end
        class LateInlineTest < ActiveSupport::TestCase
          self.use_transactional_tests = false
          def test_connection
            assert_equal 1, LateInlineRecord.connection.select_value("SELECT 1")
          end
        end
      RUBY
      diagnostics = StringIO.new
      with_client(errio: diagnostics) do |client|
        assert_equal "error", client.request(id: 80, worker: 0, timeout: 60,
                                              payload: { "code" => File.read(ORDER), "source_file" => ORDER },
                                              tests: [test])
        # The verdict can arrive before the client's stderr thread copies the
        # diagnostic. Read a full line before quit stops that thread.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until diagnostics.string.match?(/^\[daemon-child\].*\n/) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.01
        end
        cause = uri ? "uses a SQLite file: URI" : "uses an inline SQLite database #{database.inspect}"
        assert_includes diagnostics.string, "[daemon-child] RuntimeError: primary #{cause}"
        assert_includes diagnostics.string, "config/database.yml"
        assert_includes diagnostics.string, "establish_connection(:name)"
      end
    end
  end

  # A current extra schema must not be loaded again: its force:true table
  # definitions would delete rows copied from a --require file's boot setup.
  EXTRA_SCHEMA_CHECK = <<~RUBY
    require "./config/environment"
    require #{File.expand_path("../lib/mutineer/rails_worker_db", __dir__).inspect}
    require "sqlite3"
    require "tmpdir"
    ActiveRecord::Migration.verbose = false
    Dir.mktmpdir do |dir|
      extra = File.join(dir, "extra.sqlite3")
      original = {
        "test" => {
          "primary" => { "adapter" => "sqlite3", "database" => File.join(dir, "primary.sqlite3") },
          "extra" => { "adapter" => "sqlite3", "database" => extra }
        }
      }
      connect = lambda do
        ActiveRecord::Base.configurations = original
        ActiveRecord::Base.establish_connection(:primary)
      end
      connect.call
      load File.expand_path("db/schema.rb")
      tasks = ActiveRecord::Tasks::DatabaseTasks
      config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "extra")
      tasks.with_temporary_pool_for_each(env: "test", name: "extra") { tasks.load_schema(config) }
      SQLite3::Database.new(extra) { |db| db.execute("INSERT INTO extra_notes (body) VALUES ('boot row')") }
      if ENV["MUTINEER_TEST_LEGACY_SCHEMA_HELPER"] == "1"
        File.delete(extra)
        pool_helper = tasks.method(:with_temporary_pool_for_each)
        tasks.define_singleton_method(:with_temporary_connection_for_each) do |**options, &block|
          pool_helper.call(**options) { |pool| block.call(pool.connection) }
        end
        tasks.singleton_class.send(:undef_method, :with_temporary_pool_for_each)
      end
      [0, 1].each do |worker|
        connect.call
        ActiveRecord::Base.connection_pool.disconnect!
        Mutineer::RailsWorkerDb.after_fork(worker, seed: true)
        config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "extra")
        SQLite3::Database.new(config.database) do |db|
          puts "extra_worker_\#{worker}=\#{db.get_first_value('SELECT COUNT(*) FROM extra_notes')}"
        end
      end
    end
  RUBY

  def test_each_worker_keeps_boot_rows_in_a_current_second_database
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", EXTRA_SCHEMA_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    assert_includes out, "extra_worker_0=1"
    assert_includes out, "extra_worker_1=1"
  end

  def test_the_legacy_schema_helper_loads_an_absent_second_database
    env = Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
    env["MUTINEER_TEST_LEGACY_SCHEMA_HELPER"] = "1"
    out, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", EXTRA_SCHEMA_CHECK,
                                  chdir: APP, unsetenv_others: true)
    assert status.success?, out
    assert_includes out, "extra_worker_0=0"
    assert_includes out, "extra_worker_1=0"
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
        # A declared config, not an inline hash: --daemon copies only declared SQLite files (#332).
        ActiveRecord::Base.configurations = { "test" => base.merge(extra) }
        ActiveRecord::Base.establish_connection(:test)
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
      # A fork discards the connections it inherits. This stands in for it.
      ActiveRecord::Base.connection_pool.disconnect!
      db.after_fork(0, daemon.instance_variable_get(:@schema_path), seed: true)
      found[:rows] = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM orders")
      route.()
      found[:decoy] = begin
        ActiveRecord::Base.connection_pool.disconnect!
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
