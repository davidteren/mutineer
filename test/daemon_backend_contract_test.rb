# frozen_string_literal: true

require_relative "test_helper"
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

  def test_runner_publicly_answers_every_shared_invariant
    SHARED.each do |m|
      assert_respond_to Mutineer::Runner, m,
                        "DaemonBackend calls Runner.#{m}; making it private or renaming it " \
                        "breaks the daemon backend without failing the zero-dep suite"
    end
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
