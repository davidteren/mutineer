# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "mutineer/config"

# #26/#27 Phase 2 (U8): the --daemon opt-in flag + its usage guards. Drives the real
# binary so flag parsing + validation exit codes are exercised end to end; the two
# usage errors fire during validation, before any daemon boots, so this stays in the
# zero-dep suite (no fixture app bundle needed).
class CliDaemonTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN  = File.join(ROOT, "bin", "mutineer")

  def mutineer(*args)
    Open3.capture3(RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}", BIN, *args, chdir: Dir.tmpdir)
  end

  # KTD-10: --daemon and --test-command are two backends; combining them is a usage
  # error (exit 2), never a silent pick.
  def test_daemon_with_test_command_is_a_usage_error
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--daemon", "--test-command", "run %{files}")
    assert_equal 2, status.exitstatus
    assert_includes err, "choose one backend"
  end

  # The daemon must boot an app; --daemon with neither --rails nor --boot is a usage
  # error (exit 2).
  def test_daemon_without_rails_or_boot_is_a_usage_error
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--daemon")
    assert_equal 2, status.exitstatus
    assert_includes err, "needs an app to boot"
  end

  # --daemon --rails clears the daemon usage checks; the run still fails later (the
  # fixture app isn't present in the tmp dir), but NOT with a daemon usage error —
  # proving the guard accepts the valid combo rather than rejecting it.
  def test_daemon_with_rails_passes_daemon_validation
    _, err, status = mutineer("run", "x.rb", "--test", "t.rb", "--daemon", "--rails")
    refute_includes err, "needs an app to boot"
    refute_includes err, "choose one backend"
    refute_equal 0, status.exitstatus
  end

  # --daemon is settable in .mutineer.yml (KNOWN_KEYS) with boolean coercion.
  def test_daemon_is_a_known_config_key_with_boolean_coercion
    assert_includes Mutineer::KNOWN_KEYS, "daemon"
    assert_equal true,  Mutineer::Config.coerce("daemon", true, "f")
    assert_equal true,  Mutineer::Config.coerce("daemon", "true", "f")
    assert_equal false, Mutineer::Config.coerce("daemon", false, "f")
  end
end
