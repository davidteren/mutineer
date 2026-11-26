# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "json"
require "open3"
require "tmpdir"
require "mutineer/config"
require "mutineer/runner"
require "mutineer/cli"

# #26/#27 Phase 2a (U4): DaemonBackend drives the persistent daemon serially
# against the bundled fixture app and produces the SAME verdicts the in-process
# `--rails` path is designed to produce — the R1 correctness identity, strategy held
# constant (reload both sides). Tool-side runs in this process (Prism); only the
# daemon subprocess boots Rails.
class RunnerDaemonTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)

  def config_for(test_file)
    Mutineer::Config.new(
      sources: [File.join(APP, "app/models/order.rb")],
      tests: [File.join(APP, "test/models/#{test_file}")],
      project_root: APP,
      boot: "config/environment",
      rails: true,
      daemon: true,
      strategy: "reload",
      framework: "minitest"
    )
  end

  # The strong suite is built to kill every mutant on a covered line -> 100%, no
  # survivors. Proves daemon verdicts match the known-correct answers.
  def test_strong_suite_scores_100_via_daemon
    aggregate, = Mutineer::Runner.execute(config_for("order_test.rb"))
    assert_operator aggregate.killed_count, :>, 0, "strong suite should kill mutants"
    assert_empty aggregate.surviving_mutants, "strong suite leaves no survivors"
    assert_equal 100.0, aggregate.mutation_score
  end

  # The weak suite executes every method but asserts almost nothing, so arithmetic
  # mutants on the add/subtract boundary survive -> sub-100%, real survivors.
  def test_weak_suite_reports_survivors_via_daemon
    aggregate, = Mutineer::Runner.execute(config_for("order_weak_test.rb"))
    refute_empty aggregate.surviving_mutants, "weak suite should leave survivors"
    assert_operator aggregate.mutation_score, :<, 100.0
    assert_operator aggregate.killed_count, :>, 0, "weak suite still kills some"
  end

  # Successful daemon coverage narrowing: no stale "lower bound / no narrowing"
  # caveat. Fallback-only warnings live on DaemonBackend.build_coverage_map (nil map).
  def test_cli_does_not_claim_stale_daemon_lower_bound_when_map_ok
    _out, err = capture_io do
      assert_raises(SystemExit) { Mutineer::CLI.execute(config_for("order_test.rb")) }
    end
    refute_match(/--daemon score is a lower bound/, err)
    refute_match(/no coverage narrowing yet/, err)
    refute_match(/daemon coverage map unavailable/, err)
    assert_match(%r{\[mutineer\] \d+/\d+ mutants \(\d+%\)}, err,
                 "daemon serial path must emit progress on stderr")
  end

  def test_cli_reports_unpaired_sources_via_daemon
    cfg = config_for("order_test.rb")
    cfg.format = "json"
    tax = File.join(APP, "app/models/tax_table.rb")
    cfg.unpaired_sources = [tax]
    ops = Mutineer::MutatorRegistry.resolve(Mutineer::MutatorRegistry::DEFAULT_NAMES)
    jobs, = Mutineer::JobPlan.collect_jobs(Mutineer::Config.new(sources: [tax], project_root: APP), ops)
    out, _err = capture_io do
      assert_raises(SystemExit) { Mutineer::CLI.execute(cfg) }
    end
    doc = JSON.parse(out)
    assert_equal 1, doc["summary"]["unpaired_sources"]
    assert_equal jobs.size, doc["summary"]["unpaired_mutants"]
  end

  def test_daemon_coverage_map_warns_when_unavailable
    cfg = config_for("order_test.rb")
    Mutineer::DaemonClient.stub(:new, ->(*) { raise Mutineer::DaemonBootError, "boom" }) do
      _out, err = capture_io do
        map = Mutineer::DaemonBackend.build_coverage_map(cfg, cfg.tests.map { |t| File.expand_path(t, cfg.project_root) })
        assert_nil map
      end
      assert_match(/daemon coverage map unavailable/, err)
      assert_match(/DaemonBootError/, err)
    end
  end

  # #382: a mapped integration test kills mutants of a source with no paired
  # test. Builds config like config_for (absolute paths); does not use CLI.autopair!.
  def test_tests_map_runs_a_mapped_source_in_the_daemon
    test_map = [{
      sources: ["app/models/shipping_quote.rb"],
      tests: ["test/integration/shipping_quote_flow_test.rb"]
    }]
    resolved = Mutineer::Pairing.resolve_test_map(test_map, project_root: APP)
    assert_empty resolved[:unmatched]
    mapped = Mutineer::Pairing.mapped_tests_for("app/models/shipping_quote.rb", resolved)
    assert_equal ["test/integration/shipping_quote_flow_test.rb"], mapped

    config = Mutineer::Config.new(
      sources: [File.join(APP, "app/models/shipping_quote.rb")],
      tests: mapped.map { |path| File.join(APP, path) },
      project_root: APP,
      boot: "config/environment",
      rails: true,
      daemon: true,
      strategy: "reload",
      framework: "minitest"
    )
    aggregate, = Mutineer::Runner.execute(config)
    assert_equal 0, aggregate.errored_count
    assert_operator aggregate.killed_count, :>, 0
  end

  # #491 AE1: the probe test needs extra_load_path/ on $LOAD_PATH. A RUBYOPT
  # -I does not reach the daemon (#100), so without load_path every mutant
  # errors with the note. With it the daemon scores each mutant and still
  # gets no user RUBYOPT.
  def load_path_config(**settings)
    Mutineer::Config.new(
      sources: [File.join(APP, "app/models/order.rb")],
      tests: [File.join(APP, "extra_tests/load_path_probe_test.rb")],
      project_root: APP, boot: "config/environment", rails: true, daemon: true, strategy: "reload",
      framework: "minitest", cache_dir: Dir.mktmpdir("mutineer-load-path"), **settings
    )
  end

  def test_load_path_reaches_the_daemon_and_rubyopt_does_not
    env_log = File.join(Dir.mktmpdir("mutineer-load-path-env"), "rubyopt")
    user_env = { "BUNDLER_ORIG_RUBYOPT" => "-Iextra_load_path", "RUBYLIB" => nil, "BUNDLER_ORIG_RUBYLIB" => nil,
                 "LOAD_PATH_PROBE_ENV_LOG" => env_log }
    without = with_load = nil
    capture_subprocess_io do
      with_env(user_env) do
        without, = Mutineer::Runner.execute(load_path_config)
        with_load, = Mutineer::Runner.execute(load_path_config(extra_load_paths: ["extra_load_path"]))
      end
    end

    assert_equal [:error], without.results.map(&:status).uniq
    assert_equal "LoadError: cannot load such file -- load_path_probe (the daemon does not pass RUBYOPT to the app; " \
                 "if the missing file is in a directory set there, add that directory to load_path: in " \
                 ".mutineer.yml, or pass -I DIR to mutineer (it replaces that list), see #{Mutineer::DaemonClient::LOAD_PATH_GUIDE})",
                 without.results.first.details

    assert_equal({ killed: 1, no_coverage: 7 }, with_load.results.map(&:status).tally,
                 "the probe test covers and kills only the subtotal_cents mutant")
    refute_includes File.read(env_log), "extra_load_path", "the daemon still drops the user's RUBYOPT (#100)"
  end

  # AE2: the CLI with -I gives the same verdicts in-process and under
  # --daemon. In-process Rails needs the fixture's own bundle, so this runs
  # `mutineer` there, as bin/dogfood does.
  def test_load_path_flag_gives_the_same_verdicts_in_process_and_in_the_daemon
    env = ENV.to_h.reject { |key, _| key.start_with?("BUNDLE_", "BUNDLER_", "GEM_") || %w[RUBYOPT RUBYLIB].include?(key) }
    env["BUNDLE_GEMFILE"] = File.join(APP, "Gemfile")
    reports = %w[--no-daemon --daemon].to_h do |backend|
      Dir.mktmpdir("mutineer-load-path-cli") do |dir|
        report = File.join(dir, "report.json")
        _out, err, status = Open3.capture3(
          env, "bundle", "exec", "mutineer", "run", "app/models/order.rb", "--test",
          "extra_tests/load_path_probe_test.rb", "--rails", backend, "--strategy", "reload",
          "-I", "extra_load_path", "--cache-dir", File.join(dir, "cache"), "--format", "json", "--output", report,
          chdir: APP
        )
        assert_equal 0, status.exitstatus, "#{backend}: #{err}"
        doc = JSON.parse(File.read(report))
        [backend, [doc["summary"].values_at("killed", "survived", "errored", "no_coverage"),
                   doc["killed"].map { |k| k["id"] }.sort]]
      end
    end

    assert_equal [[1, 0, 0, 7]], reports.values.map(&:first).uniq, reports.inspect
    assert_equal reports["--daemon"], reports["--no-daemon"]
  end
end
