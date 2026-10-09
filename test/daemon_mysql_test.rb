# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"
require "mutineer/rails_worker_db"
require "mutineer/runner"
require "mutineer/cli"
require "open3"
require "tmpdir"

# MySQL worker databases. Skipped unless DB=mysql. The CI job sets that and
# provides MySQL 8. These tests use the fixture app's mysql2 client.
class DaemonMysqlTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)
  ROOT = File.expand_path("..", __dir__)
  ORDER = File.join(APP, "app/models/order.rb")
  TEST_FILE = File.join(APP, "test/models/order_test.rb")
  WORKER_DB = File.expand_path("../lib/mutineer/rails_worker_db.rb", __dir__)
  BASE = ENV.fetch("MYSQL_DATABASE", "mutineer_rails_test")

  def setup
    skip "set DB=mysql to run MySQL worker-database tests" unless ENV["DB"] == "mysql"
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

  def fixture_ruby(script, extra_env: {})
    Open3.capture2e(app_env.merge(extra_env), "bundle", "exec", "ruby", "-e", script,
                    chdir: APP, unsetenv_others: true)
  end

  def statuses(aggregate)
    aggregate.results.map { |result| [result.id, result.status] }.sort
  end

  def test_jobs_3_worker_databases_hold_the_base_rows_during_the_run
    client = nil
    client = Mutineer::DaemonClient.new(boot: boot_config(slots: 3), app_root: APP).start
    names = 3.times.map { |slot| Mutineer::RailsWorkerDb.mysql_worker_database(BASE, slot) }
    script = <<~RUBY
      require "mysql2"
      conn = Mysql2::Client.new(#{mysql_connect_literal("nil")})
      #{names.inspect}.each do |name|
        quoted = "`" + name.gsub("`", "``") + "`"
        count = conn.query("SELECT COUNT(*) AS c FROM \#{quoted}.seeded_rows", as: :hash).first["c"]
        puts "\#{name}=\#{count}"
      end
    RUBY
    out, status = fixture_ruby(script)
    assert status.success?, out
    names.each { |name| assert_includes out, "#{name}=1" }
  ensure
    client&.quit
  end

  def test_provision_runs_again_when_coverage_is_cached
    Dir.mktmpdir("mutineer-mysql-cache") do |dir|
      config = config_for(1)
      config.cache_dir = dir
      capture_subprocess_io { Mutineer::Runner.execute(config) }
      aggregate = nil
      _out, err = capture_subprocess_io { aggregate = Mutineer::Runner.execute(config).first }
      assert_equal 100.0, aggregate.mutation_score
      assert_includes err, "provisioned 1 mysql worker database(s) from #{BASE}"
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

  def test_structure_sql_worker_schema_matches_the_base
    path = File.join(APP, "db", "structure.sql")
    File.write(path, <<~SQL)
      CREATE TABLE structure_marks (
        id int NOT NULL,
        label varchar(20) NOT NULL,
        PRIMARY KEY (id)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    SQL
    script = <<~RUBY
      require "./config/environment"
      require "mysql2"
      require #{WORKER_DB.inspect}
      load #{File.join(APP, "db/schema.rb").inspect}
      ActiveRecord::Base.connection.execute("DELETE FROM orders")
      ActiveRecord::Base.connection.execute("INSERT INTO orders (quantity, unit_price_cents, rush, created_at, updated_at) VALUES (3, 4, 0, NOW(), NOW())")
      ActiveRecord.schema_format = :sql
      Mutineer::RailsWorkerDb.provision(1)
      name = Mutineer::RailsWorkerDb.mysql_worker_database(#{BASE.inspect}, 0)
      conn = Mysql2::Client.new(#{mysql_connect_literal(BASE.inspect)})
      def column_list(conn, schema, table)
        sql = "SELECT COLUMN_NAME AS n, COLUMN_TYPE AS t, IS_NULLABLE AS nullable, EXTRA AS extra " \
              "FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '\#{conn.escape(schema)}' " \
              "AND TABLE_NAME = '\#{conn.escape(table)}' ORDER BY ORDINAL_POSITION"
        conn.query(sql, as: :hash).map { |row| [row["n"], row["t"], row["nullable"], row["extra"]].join(":") }.join(",")
      end
      quoted = "`" + name.gsub("`", "``") + "`"
      mark = conn.query("SELECT COUNT(*) AS c FROM information_schema.TABLES WHERE TABLE_SCHEMA = '\#{conn.escape(name)}' AND TABLE_NAME = 'structure_marks'", as: :hash).first["c"]
      base_count = conn.query("SELECT COUNT(*) AS c FROM orders", as: :hash).first["c"]
      slot_count = conn.query("SELECT COUNT(*) AS c FROM \#{quoted}.orders", as: :hash).first["c"]
      base_cols = column_list(conn, #{BASE.inspect}, "orders")
      slot_cols = column_list(conn, name, "orders")
      puts "orders_match=\#{base_cols == slot_cols}"
      puts "mark=\#{mark}"
      puts "rows=\#{base_count}:\#{slot_count}"
    RUBY
    out, status = fixture_ruby(script)
    assert status.success?, out
    assert_includes out, "orders_match=true", out
    assert_includes out, "mark=1", out
    assert_match(/rows=(\d+):\1\b/, out)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_generated_column_and_foreign_key_copy_without_error
    script = <<~RUBY
      require "./config/environment"
      require "mysql2"
      require #{WORKER_DB.inspect}
      conn = Mysql2::Client.new(#{mysql_connect_literal(BASE.inspect)})
      conn.query("DROP TABLE IF EXISTS children")
      conn.query("DROP TABLE IF EXISTS parents")
      conn.query("CREATE TABLE parents (id bigint NOT NULL PRIMARY KEY, name varchar(50) NOT NULL) ENGINE=InnoDB")
      conn.query("CREATE TABLE children (id bigint NOT NULL PRIMARY KEY, parent_id bigint NOT NULL, qty int NOT NULL, price int NOT NULL, total int GENERATED ALWAYS AS (qty * price) STORED, CONSTRAINT fk_children_parent FOREIGN KEY (parent_id) REFERENCES parents (id)) ENGINE=InnoDB")
      conn.query("INSERT INTO parents (id, name) VALUES (1, 'ada')")
      conn.query("INSERT INTO children (id, parent_id, qty, price) VALUES (1, 1, 2, 5)")
      Mutineer::RailsWorkerDb.provision(1)
      name = Mutineer::RailsWorkerDb.mysql_worker_database(#{BASE.inspect}, 0)
      slot = Mysql2::Client.new(#{mysql_connect_literal("name")})
      row = slot.query("SELECT p.name AS name, c.qty AS qty, c.total AS total FROM children c JOIN parents p ON p.id = c.parent_id", as: :hash).first
      puts "copied=\#{row["name"]} \#{row["qty"]} \#{row["total"]}"
    RUBY
    out, status = fixture_ruby(script)
    assert status.success?, out
    assert_includes out, "copied=ada 2 10"
  ensure
    fixture_ruby(<<~RUBY)
      require "mysql2"
      conn = Mysql2::Client.new(#{mysql_connect_literal(BASE.inspect)})
      conn.query("DROP TABLE IF EXISTS children")
      conn.query("DROP TABLE IF EXISTS parents")
    RUBY
  end

  private

  def request(client, id, code)
    client.request(id: id, worker: 0, timeout: 60,
                   payload: { "code" => code, "source_file" => ORDER }, tests: [TEST_FILE])
  end

  # Keyword arguments for Mysql2::Client.new. `database_expr` is Ruby source.
  def mysql_connect_literal(database_expr)
    parts = []
    parts << "host: #{ENV['MYSQL_HOST'].inspect}" if ENV["MYSQL_HOST"] && !ENV["MYSQL_HOST"].empty?
    parts << "port: #{Integer(ENV['MYSQL_PORT'])}" if ENV["MYSQL_PORT"] && !ENV["MYSQL_PORT"].empty?
    parts << "username: #{ENV['MYSQL_USER'].inspect}" if ENV["MYSQL_USER"] && !ENV["MYSQL_USER"].empty?
    parts << "password: #{ENV['MYSQL_PASSWORD'].inspect}" if ENV.key?("MYSQL_PASSWORD")
    parts << "database: #{database_expr}" unless database_expr == "nil"
    parts.join(", ")
  end

  def spawn_holder(script)
    read, write = IO.pipe
    pid = spawn(app_env, "bundle", "exec", "ruby", "-e", script,
                chdir: APP, unsetenv_others: true, out: write, pgroup: true)
    write.close
    line = read.gets
    read.close
    flunk("holder did not start: #{line.inspect}") unless line&.start_with?("READY")
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
