# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "fixtures/calculator"

# C3: a SIGKILL'd child (timeout) skips Tempfile.create's ensure-unlink, orphaning
# .mutineer_mutant*.rb inside the source dir. The parent must sweep so orphans are
# impossible after a run.
class TempfileLeakTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  # Mutant files are hidden (#253); an older version wrote them without the dot.
  MUTANT_FILES = "{.,}mutineer_mutant*.rb"

  def test_timeout_orphan_is_swept_by_parent
    Dir.mktmpdir do |dir|
      src = File.join(dir, "thing.rb")
      File.write(src, "module Slow; end\n")

      # Mutant whose top-level code hangs at `load`, so a SIGKILL lands INSIDE
      # Tempfile.create -> the orphan is left behind, exactly the timeout case.
      pid = fork { Mutineer::Isolation.apply_whole_file("sleep 30\n", src) }
      sleep 0.02 until Dir.glob(File.join(dir, MUTANT_FILES)).any?
      Process.kill(:KILL, pid)
      wait_child(pid)

      refute_empty Dir.glob(File.join(dir, MUTANT_FILES)), "leak reproduced"
      Mutineer::JobPlan.sweep_orphans([dir])
      assert_empty Dir.glob(File.join(dir, MUTANT_FILES)), "parent sweep removed the orphan"
    end
  end

  # The sweep removes a file an older version left (no dot) and a new hidden one.
  def test_sweep_removes_hidden_and_older_mutant_files
    Dir.mktmpdir do |dir|
      files = %w[.mutineer_mutant20260101-1-a.rb mutineer_mutant20260101-1-b.rb].map { |f| File.join(dir, f) }
      files.each { |f| File.write(f, "") }
      Mutineer::JobPlan.sweep_orphans([dir])
      assert(files.none? { |f| File.exist?(f) })
    end
  end

  # A full normal run must leave no mutant file in the source dir.
  def test_normal_run_leaves_no_orphans
    fixtures_dir = File.expand_path("fixtures", __dir__)
    config = Mutineer::Config.new(
      sources: ["test/fixtures/calculator.rb"],
      tests: ["test/fixtures/calculator_strong_test.rb"],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    Mutineer::Runner.execute(config)
    assert_empty Dir.glob(File.join(fixtures_dir, MUTANT_FILES))
  end
end
