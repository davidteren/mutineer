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

  # A crash running ONE mutant is that mutant's verdict, not the end of the run, and
  # both daemon paths must agree on that or --jobs N stops matching --jobs 1.
  def test_a_crash_running_one_mutant_is_an_error_verdict_on_both_paths
    with_jobs do |jobs, config, source_map|
      client = Object.new
      def client.start = self
      def client.quit = nil
      def client.request(id:, **) = id.zero? ? raise("boom") : "killed"

      %i[run_serial run_parallel].each do |path|
        args = path == :run_serial ? [jobs, config, [], nil, source_map] : [jobs, 2, config, [], nil, source_map]
        results = Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
          Mutineer::DaemonBackend.send(path, *args)
        end

        assert_equal 2, results.size, "#{path}: every input job must keep a slot"
        assert_predicate results[0], :error?
        assert_match(/daemon worker crashed/, results[0].details)
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

      # The parallel path lets the abort escape a worker thread, and Ruby prints that
      # trace by default. It is expected here, so keep it out of the suite's output.
      reporting = Thread.report_on_exception
      Thread.report_on_exception = false
      begin
        %i[run_serial run_parallel].each do |path|
          args = path == :run_serial ? [jobs, config, [], nil, source_map] : [jobs, 2, config, [], nil, source_map]
          assert_raises(Mutineer::DaemonBootError, "#{path} must not score a run the daemon abandoned") do
            Mutineer::DaemonClient.stub(:new, ->(**) { client }) do
              Mutineer::DaemonBackend.send(path, *args)
            end
          end
        end
      ensure
        Thread.report_on_exception = reporting
      end
    end
  end
end
