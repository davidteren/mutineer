# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/config"
require "mutineer/runner"
require "mutineer/daemon_client"
require "tmpdir"

# #26/U7 — coverage narrowing restored on the daemon path. The daemon builds the
# coverage map app-side (Coverage started before boot) and ships it to the tool, which
# then runs each mutant against ONLY its covering tests and marks mutants on uncovered
# lines no_coverage (the Phase 1 regression, fixed). Proven against the fixture app.
class DaemonCoverageTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)

  def config_for(test_file)
    Mutineer::Config.new(
      sources: [File.join(APP, "app/models/order.rb")],
      tests: [File.join(APP, "test/models/#{test_file}")],
      project_root: APP, boot: "config/environment",
      rails: true, daemon: true, strategy: "reload", framework: "minitest"
    )
  end

  def boot_config(test_file)
    {
      project_root: APP, boot: File.join(APP, "config/environment"),
      load_paths: [File.join(APP, "test")], source_dirs: [File.join(APP, "app/models")],
      framework: "minitest", rails: true, schema: File.join(APP, "db/schema.rb"),
      coverage: true,
      sources: [File.join(APP, "app/models/order.rb")],
      tests: [File.join(APP, "test/models/#{test_file}")]
    }
  end

  # The daemon builds the map app-side and returns it over IPC (the U7 machinery).
  def test_daemon_builds_and_ships_a_coverage_map
    client = Mutineer::DaemonClient.new(boot: boot_config("order_test.rb"), app_root: APP).start
    data = begin
      client.coverage
    ensure
      client.quit
    end
    refute_nil data, "daemon returns a coverage payload"
    refute_empty data["map"], "the map is non-empty"
    assert data["map"].keys.any? { |k| k.start_with?("app/models/order.rb:") },
           "the map covers order.rb lines"
  end

  # #187: PriceList's class body runs at boot (a to_prepare initializer), so its
  # `price` line ran before any test. The daemon ships those load lines, and the
  # mutant is ran_at_load, not a false no_coverage.
  def test_a_line_that_ran_at_boot_is_ran_at_load_on_the_daemon_path
    config = Mutineer::Config.new(
      sources: [File.join(APP, "app/models/price_list.rb")],
      tests: [File.join(APP, "test/models/price_list_test.rb")],
      project_root: APP, boot: "config/environment",
      rails: true, daemon: true, strategy: "reload", framework: "minitest"
    )
    aggregate, = Mutineer::Runner.execute(config)
    statuses = aggregate.results.to_h { |r| [r.subject.name, r.status] }
    assert_equal({ price: :ran_at_load, discount: :killed }, statuses)
    assert_equal 100.0, aggregate.mutation_score
  end

  # #220: the daemon loads the --require files after the boot. TaxTable.rate runs
  # only when test/support/tax_setup.rb loads, so its mutant is ran_at_load, and
  # the test that reads that file's constant passes on the unmutated suite.
  def test_the_daemon_loads_the_require_files
    Dir.mktmpdir("mutineer-daemon-require") do |dir|
      config = Mutineer::Config.new(
        sources: [File.join(APP, "app/models/tax_table.rb")],
        tests: [File.join(APP, "test/models/tax_table_test.rb")],
        require_paths: ["test/support/tax_setup"], cache_dir: dir,
        project_root: APP, boot: "config/environment",
        rails: true, daemon: true, strategy: "reload", framework: "minitest"
      )
      aggregate, = Mutineer::Runner.execute(config)
      statuses = aggregate.results.to_h { |r| [r.subject.name, r.status] }
      assert_equal({ rate: :ran_at_load, round: :killed }, statuses)
      assert_equal 100.0, aggregate.mutation_score
    end
  end

  # #222: each worker DB starts as a copy of the base test DB after the daemon
  # boots, so a row the --require file wrote (in a table with no fixture) is
  # visible to the tests, as in-process, on every worker slot.
  def test_worker_dbs_see_rows_written_while_the_daemon_boots
    [1, 2].each do |jobs|
      Dir.mktmpdir("mutineer-daemon-seed") do |dir|
        config = Mutineer::Config.new(
          sources: [File.join(APP, "app/models/tax_table.rb")],
          tests: [File.join(APP, "test/models/seeded_row_test.rb")],
          require_paths: ["test/support/seed_setup"], cache_dir: dir, jobs: jobs,
          project_root: APP, boot: "config/environment",
          rails: true, daemon: true, strategy: "reload", framework: "minitest"
        )
        aggregate, = Mutineer::Runner.execute(config)
        statuses = aggregate.results.to_h { |r| [r.subject.name, r.status] }
        assert_equal({ rate: :no_coverage, round: :killed }, statuses, "--jobs #{jobs}")
      end
    end
  end

  # R8: a mutant on a line no provided test exercises is no_coverage (excluded from
  # score), NOT run as a false survivor. The subtotal-only suite leaves total_cents
  # and free_shipping? uncovered, so their mutants must be no_coverage.
  def test_uncovered_lines_are_no_coverage_on_the_daemon_path
    aggregate, = Mutineer::Runner.execute(config_for("order_subtotal_only_test.rb"))
    assert_operator aggregate.no_coverage_count, :>, 0,
                    "mutants on the uncovered methods come back no_coverage"
    assert_operator aggregate.covered_count, :>, 0,
                    "subtotal_cents mutants are still run (covered)"
  end

  def test_daemon_writes_the_coverage_cache_to_cache_dir
    Dir.mktmpdir("mutineer-daemon-cache") do |dir|
      config = config_for("order_subtotal_only_test.rb")
      config.cache_dir = dir
      Mutineer::Runner.execute(config)
      assert_path_exists File.join(dir, "coverage.json")
    end
  end
end
