# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"

# A worker database that cannot be provisioned ends the run. Exit 3 is the
# untrustworthy-run code, including when --threshold is off.
class DaemonProvisionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_a_provision_failed_reply_ends_the_run
    client = Mutineer::DaemonClient.allocate
    client.instance_variable_set(:@stdin, StringIO.new)
    client.define_singleton_method(:send_line) { |*| nil }
    client.define_singleton_method(:read_line) { |*| { "id" => 7, "verdict" => "provision_failed" } }

    error = assert_raises(Mutineer::DaemonBootError) do
      client.request(id: 7, payload: {}, tests: [], timeout: 1)
    end
    assert_equal "worker database provisioning failed", error.message
  end

  def test_a_worker_database_failure_exits_3_when_the_threshold_is_off
    Dir.mktmpdir("mutineer-provision") do |dir|
      boot = File.join(dir, "boot.rb")
      source = File.join(dir, "calc.rb")
      test = File.join(dir, "calc_test.rb")
      File.write(boot, "module ActiveRecord\n  class Base\n  end\nend\n")
      File.write(source, "class Calc\n  def add(a) = a + 1\nend\n")
      File.write(test, "require 'minitest/autorun'\nclass CalcTest < Minitest::Test\n  def test_ok = pass\nend\n")
      config = Mutineer::Config.new(
        sources: [source], tests: [test], operators: ["arithmetic"],
        boot: boot, rails: true, daemon: true, framework: "minitest",
        strategy: "reload", jobs: 1, threshold: 0.0,
        project_root: ROOT, cache_dir: File.join(dir, "cache"),
        explicit: [:daemon]
      )

      error = nil
      _out, err = capture_io do
        error = assert_raises(SystemExit) { Mutineer::CLI.run(config) }
      end
      assert_equal 3, error.status
      assert_includes err, "worker database provisioning failed"
    end
  end
end
