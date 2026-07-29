# frozen_string_literal: true

require_relative "test_helper"
require "English"
require "minitest/mock"
require "tmpdir"
require "mutineer/config"
require "mutineer/daemon_backend"

# #58: DaemonBackend reaches back into Runner for the invariants both backends must
# share (job collection, --since, coverage selection, path helpers). The split turned
# those intra-class calls into a cross-module contract, and every test that exercises
# it lives in DAEMON_TESTS — excluded from the zero-dep suite. So renaming or
# privatising one of the five would leave `rake test`, the load smoke and yard:strict
# all green while the daemon path raises at runtime. These checks are Rails-free and
# daemon-free on purpose: they run in the default suite and fail the moment the
# contract moves.
class DaemonBackendContractTest < Minitest::Test
  # The Runner methods DaemonBackend calls across the module boundary.
  SHARED = %i[collect_jobs filter_since coverage_selection test_load_roots source_dirs].freeze

  # Cheapest possible tripwire: privatising or renaming any of the five breaks the
  # daemon path at runtime, and nothing else in the zero-dep suite would notice.
  def test_runner_publicly_answers_every_shared_invariant
    SHARED.each do |m|
      assert_respond_to Mutineer::Runner, m,
                        "DaemonBackend calls Runner.#{m}; making it private or renaming it " \
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

  # Exercises the shared helpers for real rather than by respond_to? alone:
  # boot_config routes through Runner.test_load_roots and Runner.source_dirs.
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
                                    framework: "minitest", rails: true)
      boot = Mutineer::DaemonBackend.boot_config(config, [test])

      assert_includes boot[:load_paths], File.join(root, "test"),
                      "the test_helper root must reach the daemon so `require \"test_helper\"` resolves in each fork"
      assert_equal [File.join(root, "app/models")], boot[:source_dirs]
      assert_nil boot[:schema], "no db/schema.rb in this app, so the daemon skips worker-DB schema loading"
      assert boot[:rails]
      refute boot[:coverage], "worker daemons boot with Coverage off; only the map-building daemon enables it"
    end
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
  # a file left by a hard-killed run would survive — and one sitting in app/models
  # breaks the app's own Zeitwerk boot, not just the next Mutineer run.
  def test_an_empty_job_list_still_sweeps_orphaned_daemon_temps
    Dir.mktmpdir("mutineer-sweep") do |root|
      FileUtils.mkdir_p(File.join(root, "app"))
      source = File.join(root, "app/order.rb")
      File.binwrite(source, SOURCE)
      orphan = File.join(root, "app/mutineer_daemon20260101-1-abcdef.rb")
      File.binwrite(orphan, "class Order; end\n")

      config = Mutineer::Config.new(sources: [source], tests: [], project_root: root,
                                    framework: "minitest", only: ["NoSuchMethod"])

      Mutineer::DaemonClient.stub(:new, ->(**) { flunk "booted a daemon for zero jobs" }) do
        Mutineer::DaemonBackend.execute(config, [])
      end

      refute_path_exists orphan, "a zero-job run must still clear orphaned daemon temps"
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
end
