# frozen_string_literal: true

require_relative "test_helper"
require "English"
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

  # daemon_backend.rb calls Runner but must never require it: runner.rb requires
  # daemon_backend, so the reverse edge makes Ruby print "circular require considered
  # harmful" into the process of anyone who loads Mutineer with warnings on. Both Rake
  # tasks set warning = false, so only a child process with -w can see a regression here.
  def test_loading_the_gem_emits_no_circular_require_warning
    lib = File.expand_path("../lib", __dir__)
    # Report which daemon_backend.rb actually got loaded. Three ways this could pass
    # while proving nothing, all closed below: a silent load failure prints no warning
    # either; an installed mutineer gem would satisfy the require from somewhere else;
    # and stderr is merged here, so a backtrace naming this file would satisfy a path
    # check on its own. Hence the exit status AND the path.
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
end
