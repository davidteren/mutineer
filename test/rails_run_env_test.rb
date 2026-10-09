# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Rails reads PARALLEL_WORKERS when a test helper calls parallelize.
# Every backend must set it to 1 before that load, then restore the caller.
class RailsRunEnvTest < Minitest::Test
  BOOT = File.expand_path("fixtures/boot", __dir__)
  APP = File.join(BOOT, "app_boot.rb")
  SRC = File.join(BOOT, "widget.rb")
  STRONG = File.join(BOOT, "widget_strong_test.rb")

  def test_daemon_run_replaces_a_user_value_once_and_restores_it
    with_parallel_workers("8") do
      Dir.mktmpdir("mutineer-fork-hygiene") do |dir|
        source = File.join(dir, "empty.rb")
        File.write(source, "# no mutants\n")
        _out, err = capture_io do
          Mutineer::Runner.execute(Mutineer::Config.new(
            sources: [source], tests: [], project_root: dir,
            daemon: true, boot: "boot.rb", jobs: 4
          ))
        end
        assert_equal 1, err.scan('PARALLEL_WORKERS was "8"').size
        assert_equal "8", ENV["PARALLEL_WORKERS"]
      end
    end
  end

  def test_unset_parallel_workers_prints_no_replacement_line
    with_parallel_workers(nil) do
      Dir.mktmpdir("mutineer-fork-hygiene") do |dir|
        source = File.join(dir, "empty.rb")
        File.write(source, "# no mutants\n")
        _out, err = capture_io do
          Mutineer::Runner.execute(Mutineer::Config.new(
            sources: [source], tests: [], project_root: dir, daemon: true, boot: "boot.rb"
          ))
        end
        refute_match(/PARALLEL_WORKERS was/, err)
        assert_nil ENV["PARALLEL_WORKERS"]
      end
    end
  end

  def test_in_process_boot_sees_parallel_workers_one
    Dir.mktmpdir("mutineer-fork-hygiene") do |dir|
      probe = File.join(dir, "probe.txt")
      boot = File.join(dir, "boot.rb")
      File.write(boot, "File.write(#{probe.dump}, ENV.fetch('PARALLEL_WORKERS'))\nrequire #{APP.dump}\n")
      with_parallel_workers("8") do
        _out, err = capture_io do
          Mutineer::Runner.execute(Mutineer::Config.new(
            sources: [SRC], tests: [STRONG], boot: boot,
            strategy: "redefine", project_root: BOOT, cache_dir: dir, jobs: 1
          ))
        end
        assert_equal "1", File.read(probe)
        assert_equal "8", ENV["PARALLEL_WORKERS"]
        assert_equal 1, err.scan('PARALLEL_WORKERS was "8"').size
      end
    end
  end

  def with_parallel_workers(value)
    prior = ENV["PARALLEL_WORKERS"]
    value.nil? ? ENV.delete("PARALLEL_WORKERS") : ENV["PARALLEL_WORKERS"] = value
    yield
  ensure
    prior.nil? ? ENV.delete("PARALLEL_WORKERS") : ENV["PARALLEL_WORKERS"] = prior
  end
end
