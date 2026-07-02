# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/config"
require "mutineer/runner"
require "mutineer/daemon_client"

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
end
