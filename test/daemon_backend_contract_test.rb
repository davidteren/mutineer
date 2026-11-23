# frozen_string_literal: true

require_relative "test_helper"
require "English"
require "minitest/mock"
require "timeout"
require "tmpdir"
require "stringio"
require "mutineer/config"
require "mutineer/daemon_backend"

# #58: DaemonBackend calls JobPlan (#75) for the invariants both backends must
# share (job collection, --since, coverage selection, path helpers). The split turned
# those intra-class calls into a cross-module contract, and every test that exercises
# it lives in DAEMON_TESTS — excluded from the zero-dep suite. So renaming or
# privatising one of these would leave `rake test`, the load smoke and yard:strict
# all green while the daemon path raises at runtime. These checks are Rails-free and
# daemon-free on purpose: they run in the default suite and fail the moment the
# contract moves.
class DaemonBackendContractTest < Minitest::Test
  # #495: the daemon's clean check seconds reach the map from its coverage
  # reply. A reply without the key reads as nil, never 0.0.
  def test_coverage_reply_carries_clean_check_seconds
    config = Struct.new(:project_root, :framework).new(Dir.pwd, "minitest")
    reply = { "map" => { "a.rb:1" => ["t.rb"] }, "failed_test_files" => [], "clean_check_seconds" => 1.5 }
    map = Mutineer::DaemonBackend.send(:coverage_map_from_client, Struct.new(:coverage).new(reply), config)
    assert_in_delta 1.5, map.clean_check_seconds
    old = reply.except("clean_check_seconds")
    assert_nil Mutineer::DaemonBackend.send(:coverage_map_from_client, Struct.new(:coverage).new(old), config)
                                      .clean_check_seconds
  end

  # A reply whose map is empty (no test covers the sources) still ran the
  # clean check, so its seconds reach the timing even though no map returns.
  def test_an_empty_coverage_reply_keeps_its_clean_check_seconds
    config = Struct.new(:project_root, :framework).new(Dir.pwd, "minitest")
    reply = { "map" => {}, "failed_test_files" => [], "clean_check_seconds" => 2.5 }
    timing = {}
    map = nil
    capture_io do
      map = Mutineer::DaemonBackend.send(:coverage_map_from_client, Struct.new(:coverage).new(reply), config, timing)
    end
    assert_nil map
    assert_in_delta 2.5, timing[:clean_check_seconds]
  end

  # The JobPlan methods DaemonBackend calls across the module boundary.
  SHARED = %i[collect_jobs filter_since scope_since coverage_selection load_verdict test_load_roots source_dirs
              sweep_orphans abort_if_unclean!].freeze

  # Cheapest possible tripwire: privatising or renaming any of them breaks the
  # daemon path at runtime, and nothing else in the zero-dep suite would notice.
  def test_job_plan_publicly_answers_every_shared_invariant
    SHARED.each do |m|
      assert_respond_to Mutineer::JobPlan, m,
                        "DaemonBackend calls JobPlan.#{m}; making it private or renaming it " \
                        "breaks the daemon backend without failing the zero-dep suite"
    end
  end

  # A require cycle between runner.rb and daemon_backend.rb warns on every -w load,
  # and both Rake tasks set warning = false, so only a child process can see it. The
  # exit status and the loaded path are asserted too, or a failed load would pass this
  # by printing no warning either.
  def test_loading_the_gem_emits_no_circular_require_warning
    lib = File.expand_path("../lib", __dir__)
    script = 'require "mutineer"; print $LOADED_FEATURES.grep(/daemon_backend/).first.to_s'
    out = IO.popen([RbConfig.ruby, "-w", "-I#{lib}", "-e", script], err: %i[child out], &:read)
    status = $CHILD_STATUS

    assert_predicate status, :success?, "the child failed to load Mutineer, so this proved nothing:\n#{out}"
    assert_includes out, File.join(lib, "mutineer/daemon_backend.rb"),
                    "the child did not load this working tree, so this proved nothing"
    refute_match(/circular require/, out,
                 "a require cycle between runner.rb and daemon_backend.rb warns on every -w load")
  end

  # #75: every require_relative edge in lib/mutineer forms a DAG. Loading every
  # file enters every load-time cycle, wherever it is, and Ruby warns on each one.
  def test_loading_every_lib_file_emits_no_circular_require_warning
    lib = File.expand_path("../lib", __dir__)
    files = Dir[File.join(lib, "mutineer/**/*.rb")]
    script = 'ARGV.sort.each { |f| require f }; print $LOADED_FEATURES.size'
    out = IO.popen([RbConfig.ruby, "-w", "-I#{lib}", "-e", script, *files], err: %i[child out], &:read)

    assert_predicate $CHILD_STATUS, :success?, "the child failed to load every file, so this proved nothing:\n#{out}"
    refute_match(/circular require/, out, "a require_relative cycle in lib/mutineer warns on every -w load")
  end

  # #75: daemon_backend.rb requires what it references, so loading it alone
  # defines the shared job vocabulary it calls.
  def test_daemon_backend_loads_job_plan_on_its_own
    lib = File.expand_path("../lib", __dir__)
    script = 'require "mutineer/daemon_backend"; print Mutineer::JobPlan.respond_to?(:collect_jobs)'
    out = IO.popen([RbConfig.ruby, "-w", "-I#{lib}", "-e", script], err: %i[child out], &:read)

    assert_equal "true", out
  end

  # Exercises the shared helpers for real rather than by respond_to? alone:
  # boot_config routes through JobPlan.test_load_roots and JobPlan.source_dirs.
  def test_boot_config_resolves_load_roots_and_source_dirs
    Dir.mktmpdir("mutineer-contract") do |root|
      FileUtils.mkdir_p(File.join(root, "app/models"))
      FileUtils.mkdir_p(File.join(root, "test/models"))
      source = File.join(root, "app/models/order.rb")
      test   = File.join(root, "test/models/order_test.rb")
      File.binwrite(source, "class Order; end\n")
      File.binwrite(test, "require \"test_helper\"\n")
      File.binwrite(File.join(root, "test/test_helper.rb"), "\n")

      config = Mutineer::Config.new(sources: [source], tests: [test], project_root: root,
                                    framework: "minitest", rails: true, require_paths: ["test/support/setup"])
      boot = Mutineer::DaemonBackend.boot_config(config, [test])

      assert_equal [File.join(root, "test/support/setup")], boot[:require_paths],
                   "#220: the daemon loads the --require files after the boot"
      assert_includes boot[:load_paths], File.join(root, "test"),
                      "the test_helper root must reach the daemon so `require \"test_helper\"` resolves in each fork"
      assert_equal [File.join(root, "app/models")], boot[:source_dirs]
      assert_equal File.join(root, ".mutineer"), boot[:cache_dir]
      refute boot.key?(:schema), "#317: the booted daemon asks Rails for the schema file; the tool does not guess"
      assert boot[:rails]
      refute boot[:coverage], "worker daemons boot with Coverage off; only the map-building daemon enables it"
      assert_nil boot[:capture_timeout], "no --capture-timeout: the daemon uses the default"
      config.capture_timeout = 300
      assert_equal 300, Mutineer::DaemonBackend.boot_config(config, [test], coverage: true)[:capture_timeout],
                   "PR #183 review: the map-building daemon gets --capture-timeout"
    end
  end

  # Only a parallel worker daemon gets the shared names: one worker shares
  # nothing, so its daemon runs no shared-database check.
  def test_boot_config_sends_shared_databases_only_to_parallel_workers
    config = Mutineer::Config.new(sources: [], tests: [], project_root: Dir.pwd, framework: "minitest",
                                  shared_databases: %w[cable])

    assert_equal %w[cable], Mutineer::DaemonBackend.boot_config(config, [], parallel: true)[:shared_databases]
    assert_empty Mutineer::DaemonBackend.boot_config(config, [])[:shared_databases]
    assert_empty Mutineer::DaemonBackend.boot_config(config, [], coverage: true)[:shared_databases]
  end

  # The daemon's database report, as RailsWorkerDb.database_names gives it.
  TWO_DATABASES = { "names" => %w[primary cable], "primary" => "primary" }.freeze

  def test_a_second_database_forces_one_worker_and_names_it
    count = nil
    _out, err = capture_io { count = worker_count_for(TWO_DATABASES, [], 4) }

    assert_equal 1, count
    assert_includes err, "this app has 2 databases; Mutineer runs one worker. Parallel runs support one database."
    assert_includes err, "under shared_databases: cable."
  end

  def test_shared_databases_lifts_the_one_worker_limit
    count = nil
    _out, err = capture_io { count = worker_count_for(TWO_DATABASES, %w[cable], 4) }

    assert_equal 4, count
    assert_empty err
  end

  def test_one_database_or_one_worker_keeps_the_count_without_a_warning
    one = { "names" => %w[primary], "primary" => "primary" }
    _out, err = capture_io do
      assert_equal 4, worker_count_for(one, [], 4)
      assert_equal 1, worker_count_for(TWO_DATABASES, [], 1)
      assert_equal 3, worker_count_for(nil, [], 3), "no worker-DB adapter: nothing to count"
    end
    assert_empty err
  end

  # A typo matches no config. The database it meant stays counted, so the run
  # keeps one worker, and the warning names the real configs.
  def test_an_unknown_shared_database_warns_and_lifts_nothing
    count = nil
    _out, err = capture_io { count = worker_count_for(TWO_DATABASES, %w[cabel], 4) }

    assert_equal 1, count
    assert_includes err, "shared_databases names no test database: cabel. This app has primary, cable."
    assert_includes err, "this app has 2 databases outside shared_databases; Mutineer runs one worker."
  end

  # Each worker copies the primary database. Sharing it would leave the other
  # database unisolated, so the run stops before any mutant, at any worker count.
  def test_listing_the_primary_database_is_a_config_error
    [4, 1].each do |workers|
      error = assert_raises(Mutineer::ConfigError) { worker_count_for(TWO_DATABASES, %w[primary cable], workers) }
      assert_includes error.message, "shared_databases lists primary, the database each worker copies."
    end
  end

  # The first daemon lists the databases. When it cannot boot, nobody counted
  # them, so the run must not start a second worker that could share one.
  # A --boot app without --rails has no database routing, so it keeps its workers.
  def test_a_failed_first_boot_keeps_one_worker_on_rails
    client = Object.new
    client.define_singleton_method(:start) { raise Mutineer::DaemonBootError, "boom" }
    results = {}
    _out, err = capture_io do
      Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
        [true, false].each do |rails|
          config = Mutineer::Config.new(sources: [], tests: [], project_root: Dir.pwd, framework: "minitest",
                                        rails: rails)
          results[rails] = Mutineer::DaemonBackend.send(:prepare_run, config, [], 4)
        end
      end
    end

    assert_equal [nil, 1, nil], results[true]
    assert_equal [nil, 4, nil], results[false]
    assert_includes err, "daemon coverage map unavailable"
    assert_equal 1, err.scan("could not list this app's databases (the first daemon did not boot); " \
                             "Mutineer runs one worker.").size
  end

  # A failed lookup must not lift the guard: an uncounted database could be
  # shared without anyone listing it.
  def test_a_failed_database_lookup_keeps_one_worker
    failed = { "error" => "ActiveRecord::ConnectionNotEstablished: no pool" }
    count = nil
    _out, err = capture_io { count = worker_count_for(failed, %w[cable], 4) }

    assert_equal 1, count
    assert_includes err, "could not list this app's databases (ActiveRecord::ConnectionNotEstablished: no pool); " \
                         "Mutineer runs one worker."
    _out, err = capture_io { assert_equal 1, worker_count_for(failed, [], 1) }
    assert_empty err, "one worker was asked for, so nothing changes"
  end

  # A failed lookup that still names the primary keeps the usage error: the
  # run exits 2 instead of falling back to one worker.
  def test_a_failed_lookup_still_rejects_a_listed_primary
    failed = { "error" => "no pool", "primary" => "primary" }
    error = assert_raises(Mutineer::ConfigError) { worker_count_for(failed, %w[primary], 4) }
    assert_includes error.message, "shared_databases lists primary"

    _out, err = capture_io { assert_equal 1, worker_count_for(failed.merge("primary" => nil), %w[primary], 4) }
    assert_includes err, "could not list this app's databases (no pool)"
  end

  # Mutatable fixture for the daemon-path tests: one arithmetic operator, so the
  # Arithmetic mutator yields a real Mutation to send through job_result.
  SOURCE = "class Order\n  def total(a, b)\n    a + b\n  end\nend\n"

  # A real job pair, so the daemon paths run their actual code and the only stubbed
  # thing is the daemon itself. Stubbing job_result instead would bypass the very
  # rescue these tests exist to pin.
  def with_jobs
    Dir.mktmpdir("mutineer-daemon") do |root|
      FileUtils.mkdir_p(File.join(root, "app"))
      path = File.join(root, "app/order.rb")
      File.binwrite(path, SOURCE)
      subject = Mutineer::Project.discover([path]).first
      mutations = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, SOURCE)
      config = Mutineer::Config.new(sources: [path], tests: [], project_root: root, framework: "minitest")
      jobs = [[subject, mutations.first, "id-0"], [subject, mutations.first, "id-1"]]
      yield jobs, config, { path => SOURCE }
    end
  end

  # A daemon that dies on ONE mutant is DaemonClient's business: it respawns and
  # answers "error" for that mutant. The run must carry on, identically on both
  # paths, or --jobs N stops matching --jobs 1.
  def test_a_crash_running_one_mutant_is_an_error_verdict_on_both_paths
    with_jobs do |jobs, config, source_map|
      client = Object.new
      def client.start = self
      def client.quit = nil
      def client.request(id:, **) = id.zero? ? "error" : "killed"
      def client.last_cause = nil

      %i[run_serial run_parallel].each do |path|
        args = path == :run_serial ? [jobs, config, [], nil, source_map] : [jobs, 2, config, [], nil, source_map]
        results = Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
          Mutineer::DaemonBackend.send(path, *args)
        end

        assert_equal 2, results.size, "#{path}: every input job must keep a slot"
        assert_predicate results[0], :error?
        assert_match(/daemon verdict: error/, results[0].details)
        # subject and mutation, not just id: the reporter needs all three to place
        # an errored mutant at its file and line, and dropping them still passes an
        # id-only assertion.
        assert_equal "id-0", results[0].id
        assert_equal jobs[0][0], results[0].subject
        assert_equal jobs[0][1], results[0].mutation
        assert_predicate results[1], :killed?
        assert_equal jobs[1][0], results[1].subject
      end
    end
  end

  # #388: the cause the daemon's child sent becomes the errored mutant's details.
  def test_a_daemon_cause_reaches_the_result_on_both_paths
    with_jobs do |jobs, config, source_map|
      client = Object.new
      def client.start = self
      def client.quit = nil
      def client.request(id:, **) = id.zero? ? "error" : "killed"
      def client.last_cause = "ArgumentError: enum declared twice"

      %i[run_serial run_parallel].each do |path|
        args = path == :run_serial ? [jobs, config, [], nil, source_map] : [jobs, 2, config, [], nil, source_map]
        results = Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
          Mutineer::DaemonBackend.send(path, *args)
        end

        assert_equal "ArgumentError: enum declared twice", results[0].details, path
        assert_predicate results[1], :killed?
      end
    end
  end

  # #256: the daemon always reloads the whole file, and a concern's `included`
  # block does not run again in a class that already includes it. So a def in
  # that block is unplaceable and never sent to the daemon.
  def test_an_included_block_def_is_unplaceable_without_a_request
    with_jobs do |jobs, config, source_map|
      subject, mutation, id = jobs.first
      hook = subject.dup
      hook.hook_block = true
      client = Object.new
      def client.start = self
      def client.quit = nil
      def client.request(**) = raise("an unplaceable mutant must not reach the daemon")
      results = Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
        Mutineer::DaemonBackend.send(:run_serial, [[hook, mutation, id]], config, [], nil, source_map)
      end

      assert_equal %i[unplaceable], results.map(&:status)
      assert_equal hook, results.first.subject

      # A :maybe selection stays no_coverage, as in-process (Runner.run).
      coverage_map = Object.new
      def coverage_map.map = { "app/order.rb:3" => ["test/order_test.rb"] }
      statuses = %i[maybe run].map do |kind|
        Mutineer::JobPlan.stub(:coverage_selection, [kind, ["test/order_test.rb"]]) do
          Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
            Mutineer::DaemonBackend.send(:run_serial, [[hook, mutation, id]], config, [], coverage_map, source_map)
          end
        end.first.status
      end
      assert_equal %i[no_coverage unplaceable], statuses
    end
  end

  # #297: a def in a concern's hook block that reload can place goes to the
  # daemon with the stored def in its code and the hook-def values to place it.
  def test_a_placeable_hook_def_sends_the_stored_def
    path = File.expand_path("fixtures/singleton/concern_class_methods.rb", __dir__)
    source = File.binread(path)
    subject = Mutineer::Project.discover([path], only: "ConcernPricing#doubled").first
    mutation = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first
    config = Mutineer::Config.new(sources: [path], tests: [], project_root: File.dirname(path), framework: "minitest")
    sent = []
    client = Object.new
    def client.start = self
    def client.quit = nil
    client.define_singleton_method(:request) do |payload:, **|
      sent << payload
      "killed"
    end
    results = Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
      Mutineer::DaemonBackend.send(:run_serial, [[subject, mutation, "id-0"]], config, [], nil, { path => source })
    end

    assert_equal %i[killed], results.map(&:status)
    assert_includes sent.first["code"], "::Mutineer::ConcernBlocks.store_hook_def do"
    assert_match(%r{store_hook_def do\n\s*def doubled\(x\)\s+x / 2\s+end\nend}, sent.first["code"])
    assert_equal({ "line" => 23, "name" => "doubled", "singleton" => false }, sent.first["hook_def"])
  end

  # #479 and #492: the payload carries the reload text with a call superclass
  # kept, and the run's callback-growth log when one is set, and only then.
  def test_the_payload_keeps_a_call_superclass_and_carries_the_growth_log
    path = File.expand_path("fixtures/call_superclass.rb", __dir__)
    source = File.binread(path)
    subject = Mutineer::Project.discover([path], only: "InclusionValue#switch?").first
    mutation = Mutineer::Mutators::Comparison.new.mutations_for(subject, source).first
    config = Mutineer::Config.new(sources: [path], tests: [], project_root: File.dirname(path), framework: "minitest")
    sent = []
    client = Object.new
    def client.start = self
    def client.quit = nil
    client.define_singleton_method(:request) do |payload:, **|
      sent << payload
      "killed"
    end
    [nil, "/tmp/growth.log"].each do |log|
      Mutineer::ReloadGuards.callback_growth_log = log
      Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
        Mutineer::DaemonBackend.send(:run_serial, [[subject, mutation, "id-0"]], config, [], nil, { path => source })
      end
    end

    assert_includes sent.first["code"], "kept_superclass(::Module.nesting.first, :InclusionValue)"
    refute sent.first.key?("callback_growth_log")
    assert_equal "/tmp/growth.log", sent.last["callback_growth_log"]
  ensure
    Mutineer::ReloadGuards.callback_growth_log = nil
  end

  # #187: the daemon's map ships the lines that ran at boot, and a survivor on
  # one of them is ran_at_load, as in-process. --fail-fast stops on a survivor
  # only, so it runs on past these.
  def test_a_survivor_on_a_line_that_ran_at_boot_is_ran_at_load
    with_jobs do |jobs, config, source_map|
      config.fail_fast = true
      cov = Object.new
      def cov.start = self
      def cov.quit = nil
      def cov.coverage = { "map" => { "app/order.rb:3" => ["test/order_test.rb"] }, "failed_test_files" => [],
                           "failed_clean_tests" => [], "load_lines" => ["app/order.rb:3"],
                           "load_methods" => ["app/order.rb:2:2"] }
      coverage_map = Mutineer::DaemonClient.stub(:new, ->(**) { cov }) do
        Mutineer::DaemonBackend.build_coverage_map(config, [])
      end
      assert coverage_map.ran_at_load?(File.join(config.project_root, "app/order.rb"), 3)
      assert coverage_map.method_ran_at_load?(File.join(config.project_root, "app/order.rb"), 2, 2)

      client = Object.new
      def client.start = self
      def client.quit = nil
      def client.request(id:, **) = id.zero? ? "survived" : "killed"
      results = Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
        Mutineer::DaemonBackend.send(:run_serial, jobs, config, [], coverage_map, source_map)
      end

      assert_equal %i[ran_at_load killed], results.map(&:status)
      assert_equal %w[id-0 id-1], results.map(&:id)
    end
  end

  # #254: tests that may not have run the mutant (a `:maybe` selection) count a
  # kill, and a survivor is no_coverage, as in-process.
  def test_a_maybe_selection_turns_a_survivor_into_no_coverage
    with_jobs do |jobs, config, source_map|
      cov = Object.new
      def cov.start = self
      def cov.quit = nil
      def cov.coverage = { "map" => { "app/order.rb:3" => ["test/order_test.rb"] }, "failed_test_files" => [],
                           "failed_clean_tests" => [], "load_lines" => [] }
      coverage_map = Mutineer::DaemonClient.stub(:new, ->(**) { cov }) do
        Mutineer::DaemonBackend.build_coverage_map(config, [])
      end
      client = Object.new
      def client.start = self
      def client.quit = nil
      def client.sent = (@sent ||= [])
      def client.request(id:, tests:, **)
        sent << tests
        id.zero? ? "survived" : "killed"
      end
      results = Mutineer::JobPlan.stub(:coverage_selection, [:maybe, ["/p/test/order_test.rb"]]) do
        Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
          Mutineer::DaemonBackend.send(:run_serial, jobs, config, [], coverage_map, source_map)
        end
      end

      assert_equal %i[no_coverage killed], results.map(&:status)
      assert_equal [["/p/test/order_test.rb"]] * 2, client.sent, "the daemon runs only the :maybe tests"
    end
  end

  # A combined clean check that timed out in the daemon reaches the user as a
  # timeout: the client must pass `clean_timeouts` on to the map, or a
  # --daemon run reports a red suite with the seed hint again (#476).
  def test_a_daemon_clean_check_timeout_is_reported_as_a_timeout
    with_jobs do |_jobs, config, _source_map|
      cov = Object.new
      def cov.start = self
      def cov.quit = nil
      def cov.coverage = { "map" => {}, "failed_test_files" => [], "failed_clean_tests" => ["combined suite"],
                           "clean_timeouts" => { "combined suite" => 180 } }
      err = assert_raises(Mutineer::SmokeCheckError) do
        Mutineer::DaemonClient.stub(:new, ->(**) { cov }) do
          Mutineer::DaemonBackend.build_coverage_map(config, [])
        end
      end
      assert_includes err.message, "timed out after 180s"
      refute_includes err.message, "not green"
    end
  end

  # #500: the coverage build and the clean check get the same RUBYOPT/RUBYLIB
  # note as a mutant (#491), for the Minitest and the RSpec error layouts.
  def test_daemon_coverage_load_errors_name_the_dropped_load_variables
    load_env = { "RUBYLIB" => "test/support", "BUNDLER_ORIG_RUBYLIB" => nil,
                 "RUBYOPT" => nil, "BUNDLER_ORIG_RUBYOPT" => nil }
    with_jobs do |_jobs, config, _source_map|
      { "minitest" => "1) Error:\nRedTest#test_x:\nLoadError: cannot load such file -- helpers",
        "rspec" => "An error occurred while loading ./spec/x_spec.rb.\nFailure/Error: require \"helpers\"\n\n" \
                   "LoadError:\n  cannot load such file -- helpers" }.each do |kind, detail|
        reply = { "map" => {}, "failed_test_files" => [], "failed_clean_tests" => ["red_test.rb"],
                  "failed_clean_details" => { "red_test.rb" => detail } }
        cov = Object.new
        cov.define_singleton_method(:coverage) { reply }
        err = with_env(load_env) do
          assert_raises(Mutineer::SmokeCheckError) { Mutineer::DaemonBackend.send(:coverage_map_from_client, cov, config) }
        end
        assert_includes err.message, "does not pass RUBYLIB to the app", kind
        refute_includes err.message, "test/support", kind
      end

      cov = Object.new
      def cov.coverage = { "map" => {}, "failed_test_files" => [], "error" => "LoadError: cannot load such file -- helpers" }
      _out, warned = capture_io do
        with_env(load_env) { Mutineer::DaemonBackend.send(:coverage_map_from_client, cov, config) }
      end
      assert_match(/cannot load such file -- helpers \(the daemon does not pass RUBYLIB/, warned)

      # A boot failure wraps the LoadError after its own class name.
      _out, warned = capture_io do
        with_env(load_env) do
          Mutineer::DaemonBackend.send(:warn_coverage_fallback,
                                       "Mutineer::DaemonBootError: boot failed: LoadError: cannot load such file -- x")
        end
      end
      assert_includes warned, "does not pass RUBYLIB to the app"
    end
  end

  # The daemon side of the same contract: the coverage reply carries the map's
  # `clean_timeouts`, so the client above has something to read.
  def test_the_daemon_coverage_reply_carries_clean_timeouts
    require "coverage"
    require "mutineer/daemon_server"
    server = Mutineer::DaemonServer
    server.instance_variable_set(:@cfg, {})
    cmap = Object.new
    def cmap.build_via_fork(**) = self
    def cmap.map = {}
    def cmap.failed_test_files = []
    def cmap.failed_clean_tests = ["combined suite"]
    def cmap.failed_clean_details = {}
    def cmap.clean_timeouts = { "combined suite" => 241 }
    def cmap.clean_check_seconds = 0.5
    def cmap.load_lines = []
    def cmap.load_methods = []
    reply = Coverage.stub(:running?, false) do
      Mutineer::CoverageMap.stub(:new, ->(**) { cmap }) { server.send(:build_coverage_map) }
    end
    assert_equal({ "combined suite" => 241 }, reply["clean_timeouts"])
    # #495: and the clean check seconds, which the tool reports as timing.
    assert_in_delta 0.5, reply["clean_check_seconds"]
  ensure
    server&.instance_variable_set(:@cfg, nil)
  end

  # An empty test map still falls back to the full --test set, but the boot
  # lines it came with must still classify a survivor on one of them.
  def test_an_empty_map_runs_every_test_and_keeps_the_boot_lines
    with_jobs do |jobs, config, source_map|
      cov = Object.new
      def cov.start = self
      def cov.quit = nil
      def cov.coverage = { "map" => {}, "failed_test_files" => [], "failed_clean_tests" => [],
                           "load_lines" => ["app/order.rb:3"] }
      coverage_map = nil
      _, err = capture_io do
        coverage_map = Mutineer::DaemonClient.stub(:new, ->(**) { cov }) do
          Mutineer::DaemonBackend.build_coverage_map(config, [])
        end
      end
      assert_match(/running every mutant against the full --test set/, err)

      client = Object.new
      def client.start = self
      def client.quit = nil
      def client.tests = @tests ||= []
      def client.request(id:, tests:, **)
        self.tests << tests
        id.zero? ? "survived" : "killed"
      end
      results = Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
        Mutineer::DaemonBackend.send(:run_serial, jobs, config, ["/abs/all_test.rb"], coverage_map, source_map)
      end

      assert_equal %i[ran_at_load killed], results.map(&:status)
      assert_equal [["/abs/all_test.rb"]] * 2, client.tests, "an empty map narrows nothing"
    end
  end

  # DaemonClient raises this only after exhausting its restart budget: the daemon is
  # gone, and close_io has already run, so every later request would fail too. Scoring
  # the rest against it would print a score covering a fraction of the run.
  def test_daemon_giving_up_ends_the_run_on_both_paths
    with_jobs do |jobs, config, source_map|
      client = Object.new
      def client.start = self
      def client.quit = nil
      def client.request(**) = raise(Mutineer::DaemonBootError, "daemon crashed 3 times; aborting the run")

      %i[run_serial run_parallel].each do |path|
        args = path == :run_serial ? [jobs, config, [], nil, source_map] : [jobs, 2, config, [], nil, source_map]
        assert_raises(Mutineer::DaemonBootError, "#{path} must not score a run the daemon abandoned") do
          Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
            Mutineer::DaemonBackend.send(path, *args)
          end
        end
      end
    end
  end

  # A fault in the tool-side work (apply, the Prism parse, coverage selection) is
  # deterministic: it hits every mutant. Turning it into N error verdicts would empty
  # the denominator and blame the daemon, so it must stay fatal.
  def test_a_tool_side_fault_still_ends_the_run
    with_jobs do |jobs, config, _source_map|
      client = Object.new
      def client.start = self
      def client.quit = nil
      def client.request(**) = "killed"

      # An empty source_map makes mutation.apply fail on nil, before the daemon call.
      assert_raises(StandardError) do
        Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
          Mutineer::DaemonBackend.send(:run_serial, jobs, config, [], nil, {})
        end
      end
    end
  end

  # DaemonBootError is not the only way a client dies: close_io nils the pipes before
  # a respawn, so a client whose respawn failed would otherwise fail per-mutant
  # forever and let the run score every remaining mutant against nothing.
  def test_a_client_whose_pipes_are_gone_reports_itself_dead
    client = Mutineer::DaemonClient.allocate
    client.instance_variable_set(:@stdin, nil)

    error = assert_raises(Mutineer::DaemonBootError) do
      client.request(id: 0, payload: {}, tests: [], timeout: 1)
    end
    assert_match(/not running/, error.message)
  end

  # `--since` matching nothing is the normal case for a docs-only PR, and README
  # documents that flag for PR CI. Booting the app once for the coverage map and
  # again per worker, to score zero mutants, is pure waste.
  def test_an_empty_job_list_boots_nothing
    Dir.mktmpdir("mutineer-empty") do |root|
      config = Mutineer::Config.new(sources: [], tests: [], project_root: root,
                                    framework: "minitest", jobs: 4)

      Mutineer::DaemonClient.stub(:new, ->(**) { flunk "booted a daemon for zero jobs" }) do
        aggregate, source_map = Mutineer::DaemonBackend.execute(config, [])

        assert_equal 0, aggregate.total
        assert_empty source_map
      end
    end
  end

  # The daemon sweeps its orphaned temps at boot. Nothing boots on an empty run, so
  # a file left by a hard-killed run would survive. One an older version left in
  # app/models without the dot breaks the app's own Zeitwerk boot (#253).
  def test_an_empty_job_list_still_sweeps_orphaned_daemon_temps
    Dir.mktmpdir("mutineer-sweep") do |root|
      FileUtils.mkdir_p(File.join(root, "app"))
      source = File.join(root, "app/order.rb")
      File.binwrite(source, SOURCE)
      orphan = File.join(root, "app/mutineer_daemon20260101-#{unused_pid}-abcdef.rb")
      File.binwrite(orphan, "class Order; end\n")

      config = Mutineer::Config.new(sources: [source], tests: [], project_root: root,
                                    framework: "minitest", only: ["NoSuchMethod"])

      Mutineer::DaemonClient.stub(:new, ->(**) { flunk "booted a daemon for zero jobs" }) do
        Mutineer::DaemonBackend.execute(config, [])
      end

      refute_path_exists orphan, "a zero-job run must still clear orphaned daemon temps"
    end
  end

  # #250: a daemon that crashes mid-mutant orphans its child, which lives on
  # until its watchdog fires. The run can end, or abort, first. The sweep
  # waits that moment out, so the file cannot break the app's next boot.
  def test_a_run_sweeps_a_daemon_temp_whose_child_dies_just_after_the_run
    with_jobs do |jobs, config, source_map|
      child = fork do
        sleep 0.3
        exit!(0)
      end
      Process.detach(child)
      orphan = File.join(config.project_root, "app/.mutineer_daemon20260101-#{child}-abcdef.rb")
      aborting_run = lambda do |*|
        File.binwrite(orphan, "class Order; end\n")
        raise Mutineer::DaemonBootError, "daemon gave up"
      end
      Mutineer::JobPlan.stub(:collect_jobs, [jobs, [], source_map, {}]) do
        Mutineer::DaemonBackend.stub(:prepare_run, [nil, 1]) do
          Mutineer::DaemonBackend.stub(:run_serial, aborting_run) do
            assert_raises(Mutineer::DaemonBootError) { Mutineer::DaemonBackend.execute(config, []) }
          end
        end
      end

      refute_path_exists orphan, "the run must clear the file once its child is gone"
    end
  end

  # Same input, same answer on the other backend that can know before it pays: the
  # smoke check runs the whole suite to calibrate a timeout no mutant would use.
  def test_an_empty_job_list_skips_the_external_smoke_check
    Dir.mktmpdir("mutineer-empty-ext") do |root|
      config = Mutineer::Config.new(sources: [], tests: [], project_root: root,
                                    framework: "minitest", test_command: "false")

      Mutineer::ExternalBackend.stub(:smoke_check!, ->(*) { flunk "ran the suite for zero jobs" }) do
        aggregate, = Mutineer::Runner.execute(config)

        assert_equal 0, aggregate.total
      end
    end
  end

  # #126: every backend suppresses by the ids collect_jobs computes and hands the
  # old-format ignore matches and the new-to-old id map back unchanged. All mutants are ignored, so neither
  # backend boots or runs anything.
  def test_backends_carry_the_collect_jobs_ids_and_legacy_matches
    Dir.mktmpdir("mutineer-ids") do |root|
      source = File.join(root, "order.rb")
      # `label` has no arithmetic, so it is the one method with no mutants (#386).
      text = SOURCE.sub(/end\n\z/, "\n  def label\n    :order\n  end\nend\n")
      File.binwrite(source, text)
      ops = Mutineer::MutatorRegistry.resolve(%w[arithmetic])
      probe = Mutineer::Config.new(sources: [source], project_root: root)
      jobs, = Mutineer::JobPlan.collect_jobs(probe, ops)
      refute_empty jobs
      subject = jobs.first[0]
      legacy = Mutineer::MutantId.legacy_for_subject(subject, text, jobs.select { |j| j[0] == subject }.map { |j| j[1] })
      ignore = legacy + jobs.reject { |j| j[0] == subject }.map { |j| j[2] }

      config = ->(**kw) { Mutineer::Config.new(sources: [source], project_root: root, framework: "minitest",
                                                operators: %w[arithmetic], ignore: ignore, **kw) }
      _, expected_ignored, _, extras = Mutineer::JobPlan.collect_jobs(config.(), ops)
      refute_empty extras[:legacy_ignore_matches]

      daemon = Mutineer::DaemonClient.stub(:new, ->(**) { flunk "booted a daemon" }) do
        Mutineer::DaemonBackend.execute(config.(daemon: true), ops)
      end
      external = Mutineer::ExternalBackend.stub(:smoke_check!, ->(*) { flunk "ran the suite" }) do
        Mutineer::Runner.execute(config.(test_command: "false %{files}"))
      end
      [daemon, external].each do |aggregate, _, run_extras|
        assert_equal expected_ignored.map(&:id), aggregate.results.map(&:id)
        assert_equal extras[:legacy_ignore_matches], run_extras[:legacy_ignore_matches]
        # The --baseline diff needs every new id's old id to read an old-format baseline.
        refute_empty extras[:id_map]
        assert_equal extras[:id_map], run_extras[:id_map]
        # The method counts (#386) reach every backend's report unchanged.
        assert_equal 2, extras[:subjects]
        assert_equal [{ subject: "Order#label", file: source, line: 6 }], extras[:unmutated_subjects]
        assert_equal extras[:subjects], run_extras[:subjects]
        assert_equal extras[:unmutated_subjects], run_extras[:unmutated_subjects]
      end
    end
  end

  # #374: a run that never forks still returns the dropped-copy ids collect_jobs recorded.
  def test_backends_carry_dropped_copy_ids
    Dir.mktmpdir("mutineer-copies") do |root|
      source = File.join(root, "str.rb")
      File.binwrite(source, "class Str\n  def a\n    \"hi\" # mutineer:disable-line\n  end\nend\n")
      ops = Mutineer::MutatorRegistry.resolve(%w[literal_mutation string_literal])
      config = lambda { |**kw|
        Mutineer::Config.new(sources: [source], project_root: root, framework: "minitest",
                             operators: %w[literal_mutation string_literal], **kw)
      }
      jobs, ignored, _map, extras = Mutineer::JobPlan.collect_jobs(config.call, ops)
      assert_empty jobs
      assert_equal 1, ignored.size
      refute_empty extras[:copies]

      daemon = Mutineer::DaemonClient.stub(:new, ->(**) { flunk "booted a daemon" }) do
        Mutineer::DaemonBackend.execute(config.call(daemon: true), ops)
      end
      external = Mutineer::ExternalBackend.stub(:smoke_check!, ->(*) { flunk "ran the suite" }) do
        Mutineer::Runner.execute(config.call(test_command: "false %{files}"))
      end
      [daemon, external].each do |_aggregate, _map, run_extras|
        assert_equal extras[:copies], run_extras[:copies]
        assert_equal extras[:dropped_id_map], run_extras[:dropped_id_map]
      end
    end
  end

  # A daemon that dies before accepting the boot payload makes the write raise
  # Errno::EPIPE. Left as a SystemCallError it reaches the CLI as a usage error
  # (exit 2), which would tell CI the flags were wrong rather than the daemon died.
  def test_a_daemon_that_dies_before_the_handshake_is_a_boot_error
    client = Mutineer::DaemonClient.allocate
    client.instance_variable_set(:@boot, {})
    client.instance_variable_set(:@app_root, Dir.pwd)
    client.instance_variable_set(:@errio, StringIO.new)
    def client.app_env = {}
    def client.send_line(_obj) = raise(Errno::EPIPE)

    error = assert_raises(Mutineer::DaemonBootError) { client.send(:spawn_daemon) }
    assert_match(/could not be started/, error.message)
  end

  # queue.clear is the only parallel-specific logic here, and deleting it left the
  # suite green: join re-raises either way. Pin the sibling stop with more jobs than
  # workers, so a healthy worker cannot quietly finish the whole queue.
  def test_a_dead_daemon_stops_the_other_workers
    with_jobs do |jobs, config, source_map| # rubocop:disable Lint/UnusedBlockArgument
      subject, mutation, = jobs.first
      many = Array.new(12) { |i| [subject, mutation, "id-#{i}"] }
      map = { subject.file => SOURCE }

      # A latch rather than a sleep: the healthy worker holds inside its first request
      # until the dying one has aborted, so what it does next is decided by whether
      # the queue was drained, not by timing.
      gate = Queue.new

      dying = Object.new
      dying.instance_variable_set(:@gate, gate)
      def dying.start = self
      def dying.quit = nil
      def dying.request(**)
        @gate << :aborted
        raise(Mutineer::DaemonBootError, "daemon crashed 3 times; aborting the run")
      end

      healthy = Object.new
      healthy.instance_variable_set(:@seen, [])
      healthy.instance_variable_set(:@gate, gate)
      def healthy.start = self
      def healthy.quit = nil
      def healthy.seen = @seen
      def healthy.request(id:, **)
        @seen << id
        @gate.pop      # wait for the abort
        @gate << :done # never block a later call
        "killed"
      end

      queue = [dying, healthy]
      assert_raises(Mutineer::DaemonBootError) do
        Mutineer::DaemonClient.stub(:new, ->(**) { queue.shift }) do
          Mutineer::DaemonBackend.send(:run_parallel, many, 2, config, [], nil, map)
        end
      end

      assert_operator healthy.seen.size, :<=, 2,
                      "the healthy worker kept draining the queue after the daemon gave up " \
                      "(#{healthy.seen.size} of #{many.size} jobs)"
    end
  end

  # Not only a dead daemon: any error that escapes a worker, a plain defect or
  # one outside StandardError, stops the other workers. Every daemon has quit
  # before the error leaves, so the end-of-run sweep sees each child gone.
  def test_any_worker_error_stops_the_other_workers_and_quits_every_daemon
    with_jobs do |jobs, config, source_map| # rubocop:disable Lint/UnusedBlockArgument
      subject, mutation, = jobs.first
      many = Array.new(12) { |i| [subject, mutation, "id-#{i}"] }
      map = { subject.file => SOURCE }

      [RuntimeError, SystemStackError].each do |error|
        gate = Queue.new
        quits = Queue.new

        dying = Object.new
        dying.instance_variable_set(:@gate, gate)
        dying.instance_variable_set(:@error, error)
        dying.instance_variable_set(:@quits, quits)
        def dying.start = self
        def dying.quit = @quits << :dying
        def dying.request(**)
          @gate << :aborted
          raise @error, "a defect"
        end

        healthy = Object.new
        healthy.instance_variable_set(:@seen, [])
        healthy.instance_variable_set(:@gate, gate)
        healthy.instance_variable_set(:@quits, quits)
        def healthy.start = self
        def healthy.quit = @quits << :healthy
        def healthy.seen = @seen
        def healthy.request(id:, **)
          @seen << id
          @gate.pop
          @gate << :done
          "killed"
        end

        # The dying worker comes second, so the main thread joins the healthy one
        # first. Only the dying worker's own queue.clear can stop it there.
        queue = [healthy, dying]
        assert_raises(error) do
          Mutineer::DaemonClient.stub(:new, ->(**) { queue.shift }) do
            Mutineer::DaemonBackend.send(:run_parallel, many, 2, config, [], nil, map)
          end
        end

        assert_operator healthy.seen.size, :<=, 2, "#{error}: the healthy worker kept draining the queue"
        assert_equal %i[dying healthy], Array.new(quits.size) { quits.pop }.uniq.sort,
                     "#{error}: every daemon must quit before the error leaves run_parallel"
      end
    end
  end

  # A Ctrl-C while the second daemon boots must still quit the first one.
  def test_an_interrupt_during_parallel_startup_quits_every_started_daemon
    with_jobs do |jobs, config, source_map|
      quits = []
      first = Object.new
      first.instance_variable_set(:@quits, quits)
      def first.start = self
      def first.quit = @quits << :first
      second = Object.new
      second.instance_variable_set(:@quits, quits)
      def second.start = raise(Interrupt)
      def second.quit = @quits << :second

      queue = [first, second]
      assert_raises(Interrupt) do
        Mutineer::DaemonClient.stub(:new, ->(**) { queue.shift }) do
          Mutineer::DaemonBackend.send(:run_parallel, jobs, 2, config, [], nil, source_map)
        end
      end

      assert_equal %i[first second], quits.uniq.sort, "each daemon that began to boot must quit"
    end
  end

  # Ctrl-C lands in the main thread while every worker waits on its daemon.
  # Each worker still quits its daemon before the Interrupt leaves.
  def test_a_ctrl_c_while_workers_run_quits_every_daemon
    with_jobs do |jobs, config, source_map|
      quits = Queue.new
      clients = Array.new(2) { |n| waiting_client(n, quits) }

      interrupt_main_after([0.2]) do
        assert_raises(Interrupt) do
          Mutineer::DaemonClient.stub(:new, ->(**) { clients.shift }) do
            Mutineer::DaemonBackend.send(:run_parallel, jobs, 2, config, [], nil, source_map)
          end
        end
      end

      assert_equal [0, 1], Array.new(quits.size) { quits.pop }.uniq.sort
    end
  end

  # An exception raised into the main thread from outside (a caller's
  # Timeout) ends the run at once. It is not mistaken for a worker's error,
  # which would let the workers score every remaining mutant first.
  def test_a_callers_timeout_ends_a_parallel_run_at_once
    with_jobs do |jobs, config, source_map|
      subject, mutation, = jobs.first
      many = Array.new(40) { |i| [subject, mutation, "id-#{i}"] }
      scored = Queue.new
      clients = Array.new(2) do
        client = Object.new
        client.define_singleton_method(:start) { self }
        client.define_singleton_method(:quit) { nil }
        client.define_singleton_method(:request) do |**|
          scored << 1
          sleep 0.1
          "killed"
        end
        client
      end

      assert_raises(Timeout::Error) do
        Mutineer::DaemonClient.stub(:new, ->(**) { clients.shift }) do
          Timeout.timeout(0.3) { Mutineer::DaemonBackend.send(:run_parallel, many, 2, config, [], nil, source_map) }
        end
      end
      assert_operator scored.size, :<, 20, "the run kept scoring after the caller's timeout"
    end
  end

  # A refused thread (EAGAIN under a high --jobs) can leave a started worker
  # killed before its block ran, so its own ensure never quits its daemon.
  # Every daemon must still quit.
  def test_a_refused_worker_thread_still_quits_every_daemon
    Dir.mktmpdir("mutineer-threads") do |root|
      config = Mutineer::Config.new(sources: [], tests: [], project_root: root, framework: "minitest")
      quits = []
      pending = Array.new(3) do |n|
        client = Object.new
        client.define_singleton_method(:start) { self }
        client.define_singleton_method(:quit) { quits << n }
        client
      end
      real_new = Thread.method(:new)
      calls = 0
      refuse_second = lambda do |*args, &block|
        calls += 1
        raise ThreadError, "can't create Thread: Resource temporarily unavailable" if calls == 2

        real_new.call(*args, &block)
      end

      assert_raises(ThreadError) do
        Mutineer::DaemonClient.stub(:new, ->(**) { pending.shift }) do
          Thread.stub(:new, refuse_second) do
            Mutineer::DaemonBackend.send(:run_parallel, [], 3, config, [], nil, {})
          end
        end
      end
      assert_equal [0, 1, 2], quits.uniq.sort
    end
  end

  # A second Ctrl-C during that cleanup exits at once. It does not wait for a
  # daemon that is slow to quit.
  def test_a_second_ctrl_c_does_not_wait_for_slow_daemon_quits
    with_jobs do |jobs, config, source_map|
      clients = Array.new(2) { |n| waiting_client(n, Queue.new, quit_delay: 3) }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      interrupt_main_after([0.2, 0.3]) do
        assert_raises(Interrupt) do
          Mutineer::DaemonClient.stub(:new, ->(**) { clients.shift }) do
            Mutineer::DaemonBackend.send(:run_parallel, jobs, 2, config, [], nil, source_map)
          end
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 2, "a second Ctrl-C must exit without waiting for each quit"
    end
  end

  # A daemon file whose owner stays alive (here: this test process, as for a
  # concurrent run) stays in place. The sweep waits SWEEP_GRACE, then gives up.
  def test_the_end_of_run_sweep_gives_up_on_a_live_owner_after_its_grace
    Dir.mktmpdir("mutineer-sweep") do |root|
      FileUtils.mkdir_p(File.join(root, "app"))
      source = File.join(root, "app/order.rb")
      File.binwrite(source, SOURCE)
      live = File.join(root, "app/.mutineer_daemon20260101-#{Process.pid}-abcdef.rb")
      File.binwrite(live, "class Order; end\n")
      config = Mutineer::Config.new(sources: [source], tests: [], project_root: root,
                                    framework: "minitest", only: ["NoSuchMethod"])

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Mutineer::DaemonClient.stub(:new, ->(**) { flunk "booted a daemon for zero jobs" }) do
        Mutineer::DaemonBackend.execute(config, [])
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_path_exists live, "a file a live process owns must stay"
      assert_operator elapsed, :>=, Mutineer::DaemonBackend::SWEEP_GRACE
      assert_operator elapsed, :<, Mutineer::DaemonBackend::SWEEP_GRACE + 2, "the sweep must give up"
    end
  end

  # #416: a serial Rails run keeps the prepare daemon until its last mutant
  # has run, so a lock still covers the databases while the worker respawns.
  def test_a_serial_rails_run_keeps_the_prepare_daemon_until_the_last_mutant
    with_jobs do |jobs, config, source_map|
      config.rails = true
      order = []
      prepare = Object.new
      prepare.define_singleton_method(:quit) { order << :prepare_quit }
      worker = Object.new
      worker.define_singleton_method(:start) { order << :worker_start; self }
      worker.define_singleton_method(:quit) { order << :worker_quit }
      worker.define_singleton_method(:request) { |**| order << :request; "killed" }

      Mutineer::DaemonClient.stub(:new, ->(**) { worker }) do
        Mutineer::DaemonBackend.send(:run_serial, jobs, config, [], nil, source_map, prepare)
      end
      assert_equal %i[worker_start request request prepare_quit worker_quit], order
    end
  end

  # A run without --rails takes no database lock, so it does not keep an idle
  # booted app: the prepare daemon quits once the worker has booted.
  def test_a_serial_run_without_rails_quits_the_prepare_daemon_after_the_worker_boots
    with_jobs do |jobs, config, source_map|
      order = []
      prepare = Object.new
      prepare.define_singleton_method(:quit) { order << :prepare_quit }
      worker = Object.new
      worker.define_singleton_method(:start) { order << :worker_start; self }
      worker.define_singleton_method(:quit) { order << :worker_quit }
      worker.define_singleton_method(:request) { |**| order << :request; "killed" }

      Mutineer::DaemonClient.stub(:new, ->(**) { worker }) do
        Mutineer::DaemonBackend.send(:run_serial, jobs, config, [], nil, source_map, prepare)
      end
      assert_equal %i[worker_start prepare_quit request request worker_quit], order
    end
  end

  # #416: a mutant request that raises ends the run, and both daemons still quit.
  def test_a_serial_request_that_raises_still_quits_both_daemons
    with_jobs do |jobs, config, source_map|
      config.rails = true
      order = []
      prepare = Object.new
      prepare.define_singleton_method(:quit) { order << :prepare_quit }
      worker = Object.new
      worker.define_singleton_method(:start) { self }
      worker.define_singleton_method(:quit) { order << :worker_quit }
      worker.define_singleton_method(:request) { |**| raise Mutineer::DaemonBootError, "daemon crashed 4 times" }

      assert_raises(Mutineer::DaemonBootError) do
        Mutineer::DaemonClient.stub(:new, ->(**) { worker }) do
          Mutineer::DaemonBackend.send(:run_serial, jobs, config, [], nil, source_map, prepare)
        end
      end
      assert_equal %i[prepare_quit worker_quit], order
    end
  end

  # The prepare daemon holds the database lock. In a parallel run it must stay
  # up until each worker daemon has booted, then quit. Quitting first lets
  # another run drop the worker databases.
  def test_a_parallel_run_keeps_the_prepare_daemon_until_workers_boot
    with_jobs do |jobs, config, source_map|
      order = []
      prepare = Object.new
      prepare.define_singleton_method(:quit) { order << :prepare_quit }
      workers = Array.new(2) do
        client = Object.new
        client.define_singleton_method(:start) { order << :worker_start; self }
        client.define_singleton_method(:quit) { order << :worker_quit }
        client.define_singleton_method(:request) { |**| "killed" }
        client
      end
      queue = workers.dup
      Mutineer::DaemonClient.stub(:new, ->(**) { queue.shift }) do
        Mutineer::DaemonBackend.send(:run_parallel, jobs, 2, config, [], nil, source_map, prepare)
      end
      assert_equal %i[worker_start worker_start], order[0, 2]
      assert order.index(:prepare_quit) > order.rindex(:worker_start)
      assert order.index(:prepare_quit) < order.index(:worker_quit)
    end
  end

  # #416, gap 3: with no prepare daemon, a Rails run's one worker boots as
  # "solo", so it takes the exclusive lock and copies its own database. A
  # --boot run without --rails, or a run with a prepare daemon, keeps "worker".
  def test_a_serial_run_without_a_prepare_daemon_boots_a_solo_worker_on_rails
    with_jobs do |jobs, config, source_map|
      roles = []
      worker = Object.new
      worker.define_singleton_method(:start) { self }
      worker.define_singleton_method(:quit) { nil }
      worker.define_singleton_method(:request) { |**| "killed" }
      prepare = Object.new
      prepare.define_singleton_method(:quit) { nil }
      new_client = lambda do |boot:, **|
        roles << boot[:db_role]
        worker
      end

      Mutineer::DaemonClient.stub(:new, new_client) do
        [[true, nil], [false, nil], [true, prepare]].each do |rails, prepare_client|
          config.rails = rails
          Mutineer::DaemonBackend.send(:run_serial, jobs, config, [], nil, source_map, prepare_client)
        end
      end
      assert_equal %w[solo worker worker], roles
    end
  end

  # #416, gap 3: a "solo" daemon provisions exactly one slot at boot. An
  # unknown role provisions the default two, so this fails without the branch.
  def test_a_solo_daemon_provisions_one_slot_at_boot
    require "mutineer/daemon_server"
    require "mutineer/rails_worker_db"
    slots = []
    Mutineer::RailsWorkerDb.stub(:available?, true) do
      Mutineer::RailsWorkerDb.stub(:ruby_schema_path, nil) do
        Mutineer::RailsWorkerDb.stub(:provision, ->(count) { slots << count }) do
          Mutineer::RailsWorkerDb.stub(:prepare_worker!, -> { flunk "a solo daemon must not take only the shared lock" }) do
            Mutineer::DaemonServer.send(:setup_worker_db, { "db_role" => "solo" })
          end
        end
      end
    end
    assert_equal [1], slots
  ensure
    %i[@worker_db @schema_path @shared_databases @slot_ready].each do |ivar|
      Mutineer::DaemonServer.instance_variable_set(ivar, nil)
    end
  end

  # #416 review: a solo daemon copies its database inside setup_worker_db. A
  # LoadError from that copy (a MySQL schema.rb that requires a missing file)
  # must fail the boot. Rescued as "routing unavailable", it would let the
  # daemon run mutants against the app's own test database.
  def test_a_load_error_while_a_solo_daemon_copies_fails_the_boot
    require "mutineer/daemon_server"
    require "mutineer/rails_worker_db"
    errio = StringIO.new
    Mutineer::DaemonServer.instance_variable_set(:@errio, errio)
    failing_copy = ->(_count) { raise LoadError, "cannot load such file -- missing_schema_helper" }
    Mutineer::RailsWorkerDb.stub(:available?, true) do
      Mutineer::RailsWorkerDb.stub(:ruby_schema_path, nil) do
        Mutineer::RailsWorkerDb.stub(:provision, failing_copy) do
          error = assert_raises(LoadError) do
            Mutineer::DaemonServer.send(:setup_worker_db, { "db_role" => "solo" })
          end
          assert_includes error.message, "missing_schema_helper"
        end
      end
    end
    refute_includes errio.string, "worker-DB routing unavailable"
  ensure
    %i[@worker_db @schema_path @shared_databases @slot_ready @errio].each do |ivar|
      Mutineer::DaemonServer.instance_variable_set(ivar, nil)
    end
  end

  def test_prepare_run_keeps_the_client_until_the_caller_quits_it
    Dir.mktmpdir("mutineer-prepare") do |root|
      config = Mutineer::Config.new(sources: [], tests: [], project_root: root, framework: "minitest")
      quits = 0
      client = Object.new
      client.define_singleton_method(:start) { self }
      client.define_singleton_method(:databases) { nil }
      client.define_singleton_method(:provision) { |_count| nil }
      client.define_singleton_method(:coverage) do
        { "map" => { "app/order.rb:1" => ["test/order_test.rb"] }, "failed_test_files" => [] }
      end
      client.define_singleton_method(:quit) { quits += 1 }

      returned = nil
      Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
        _map, count, returned = Mutineer::DaemonBackend.send(:prepare_run, config, [], 2)
        assert_equal 2, count
        assert_equal 0, quits
        assert_same client, returned
      end
      returned.quit
      assert_equal 1, quits
    end
  end

  def test_prepare_run_quits_the_client_when_provision_is_interrupted
    Dir.mktmpdir("mutineer-prepare") do |root|
      config = Mutineer::Config.new(sources: [], tests: [], project_root: root, framework: "minitest")
      stop = Class.new(Exception) # rubocop:disable Lint/InheritException
      quits = 0
      client = Object.new
      client.define_singleton_method(:start) { self }
      client.define_singleton_method(:databases) { nil }
      client.define_singleton_method(:provision) { |_count| raise stop }
      client.define_singleton_method(:quit) { quits += 1 }

      Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
        assert_raises(stop) { Mutineer::DaemonBackend.send(:prepare_run, config, [], 2) }
      end
      assert_equal 1, quits
    end
  end

  def test_a_failed_worker_boot_still_quits_the_prepare_daemon
    order = []
    prepare = Object.new
    prepare.define_singleton_method(:quit) { order << :prepare_quit }
    worker = Object.new
    worker.define_singleton_method(:start) { order << :worker_start; raise "boot failed" }
    worker.define_singleton_method(:quit) { order << :worker_quit }

    config = Mutineer::Config.new(sources: [], tests: [], project_root: Dir.pwd, framework: "minitest")
    assert_raises(RuntimeError) do
      Mutineer::DaemonClient.stub(:new, ->(**) { worker }) do
        Mutineer::DaemonBackend.send(:run_serial, [], config, [], nil, {}, prepare)
      end
    end
    # The worker is quit too: a daemon whose boot was interrupted must not stay up.
    assert_equal %i[worker_start prepare_quit worker_quit], order
  end

  # #392: a mutant that Ruby cannot load is skipped tool-side and never sent to
  # the daemon, where it would fail to load.
  def test_a_mutant_ruby_cannot_load_is_skipped_without_a_daemon_request
    with_jobs do |jobs, config, source_map|
      subject, mutation, = jobs[0]
      client = Object.new
      def client.request(**) = raise("the daemon must not receive an invalid mutant")
      job = [subject, mutation.with(replacement: "("), "id-0"]
      result = Mutineer::DaemonBackend.send(:job_result, job, 0, client, 0, config, nil, [], source_map)
      assert_predicate result, :skipped?
      assert_equal "id-0", result.id
    end
  end

  private

  # @return [Integer] DaemonBackend.worker_count_for, a private helper.
  def worker_count_for(databases, shared, workers)
    Mutineer::DaemonBackend.send(:worker_count_for, databases, shared, workers)
  end

  # A stub daemon client whose request blocks until its worker thread is killed.
  def waiting_client(name, quits, quit_delay: 0)
    client = Object.new
    client.instance_variable_set(:@name, name)
    client.instance_variable_set(:@quits, quits)
    client.instance_variable_set(:@quit_delay, quit_delay)
    def client.start = self
    def client.request(**) = sleep
    def client.quit
      sleep @quit_delay
      @quits << @name
    end
    client
  end

  # Raises Interrupt in the calling thread after each delay, like Ctrl-C, while
  # the block runs. The interrupter stops when the block ends, so a stray
  # Interrupt cannot reach the test runner.
  def interrupt_main_after(delays)
    main = Thread.current
    interrupter = Thread.new do # rubocop:disable ThreadSafety/NewThread
      delays.each do |delay|
        sleep delay
        main.raise(Interrupt)
      end
    end
    yield
  ensure
    interrupter&.kill
  end
end
