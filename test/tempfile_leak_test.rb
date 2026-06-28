# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "fixtures/calculator"

# C3: a SIGKILL'd child (timeout) skips Tempfile.create's ensure-unlink, orphaning
# mutineer_mutant*.rb inside the source dir. The parent must sweep so orphans are
# impossible after a run.
class TempfileLeakTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_timeout_orphan_is_swept_by_parent
    Dir.mktmpdir do |dir|
      src = File.join(dir, "thing.rb")
      File.write(src, "module Slow; end\n")

      # Mutant whose top-level code hangs at `load`, so a SIGKILL lands INSIDE
      # Tempfile.create -> the orphan is left behind, exactly the timeout case.
      pid = fork { Mutineer::Isolation.apply_whole_file("sleep 30\n", src) }
      sleep 0.02 until Dir.glob(File.join(dir, "mutineer_mutant*.rb")).any?
      Process.kill(:KILL, pid)
      Process.wait(pid)

      refute_empty Dir.glob(File.join(dir, "mutineer_mutant*.rb")), "leak reproduced"
      Mutineer::Runner.sweep_orphans([dir])
      assert_empty Dir.glob(File.join(dir, "mutineer_mutant*.rb")), "parent sweep removed the orphan"
    end
  end

  # A full normal run must leave no mutineer_mutant*.rb in the source dir.
  def test_normal_run_leaves_no_orphans
    fixtures_dir = File.expand_path("fixtures", __dir__)
    config = Mutineer::Config.new(
      sources: ["test/fixtures/calculator.rb"],
      tests: ["test/fixtures/calculator_strong_test.rb"],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    Mutineer::Runner.execute(config)
    assert_empty Dir.glob(File.join(fixtures_dir, "mutineer_mutant*.rb"))
  end
end
