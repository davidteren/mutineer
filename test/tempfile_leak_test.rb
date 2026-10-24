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
      dead = unused_pid
      files = %W[.mutineer_mutant20260101-#{dead}-a.rb mutineer_mutant20260101-#{dead}-b.rb].map { |f| File.join(dir, f) }
      files.each { |f| File.write(f, "") }
      Mutineer::JobPlan.sweep_orphans([dir])
      assert(files.none? { |f| File.exist?(f) })
    end
  end

  # #295: a second run sweeps the source dir before its boot. A file whose
  # creating pid still runs belongs to that live run, so it stays.
  def test_sweep_keeps_a_mutant_file_whose_creator_is_alive
    Dir.mktmpdir do |dir|
      live = File.join(dir, ".mutineer_mutant20260101-#{Process.pid}-live.rb")
      dead = File.join(dir, ".mutineer_mutant20260101-#{unused_pid}-dead.rb")
      [live, dead].each { |f| File.write(f, "") }

      assert_equal [live], Mutineer::JobPlan.sweep_orphans([dir])
      assert File.exist?(live), "a live run's mutant file must stay"
      refute File.exist?(dead), "a dead owner's file is an orphan"
    end
  end

  # #295: a lock keeps the file too, even when the pid in the name is gone.
  def test_sweep_keeps_a_locked_mutant_file_when_the_name_pid_is_dead
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".mutineer_mutant20260101-#{unused_pid}-locked.rb")
      File.open(path, "w") do |file|
        file.flock(File::LOCK_EX)
        Mutineer::JobPlan.sweep_orphans([dir])
        assert File.exist?(path), "a lock means another process still owns the file"
      end
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
