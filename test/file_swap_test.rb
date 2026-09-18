# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "mutineer/file_swap"

# #27 (U2): on-disk mutant swap must restore the original on every exit path —
# the working tree is never left mutated. Mirrors the tempfile-orphan discipline
# (parent sweep + startup self-heal) so even a SIGKILL leaves nothing behind.
class FileSwapTest < Minitest::Test
  def with_file(content)
    Dir.mktmpdir("mutineer-swap") do |dir|
      path = File.join(dir, "source.rb")
      File.binwrite(path, content)
      yield dir, path
    end
  end

  def test_mutated_during_block_original_after
    with_file("original\n") do |_dir, path|
      seen = nil
      Mutineer::FileSwap.with(path, "mutated\n") { seen = File.binread(path) }
      assert_equal "mutated\n", seen
      assert_equal "original\n", File.binread(path)
    end
  end

  def test_backup_removed_after_clean_run
    with_file("original\n") do |dir, path|
      Mutineer::FileSwap.with(path, "mutated\n") { :ok }
      assert_empty Dir.glob(File.join(dir, "*#{Mutineer::FileSwap::BACKUP_SUFFIX}"))
    end
  end

  def test_restores_on_raise_and_propagates
    with_file("original\n") do |_dir, path|
      assert_raises(RuntimeError) do
        Mutineer::FileSwap.with(path, "mutated\n") { raise "boom" }
      end
      assert_equal "original\n", File.binread(path)
    end
  end

  def test_returns_block_value
    with_file("original\n") do |_dir, path|
      assert_equal 42, Mutineer::FileSwap.with(path, "mutated\n") { 42 }
    end
  end

  # Byte-exact: encoding, trailing newline, and CRLF must survive the round trip.
  def test_byte_exact_restoration
    original = "# frozé\r\nx = 1\n".b
    with_file(original) do |_dir, path|
      Mutineer::FileSwap.with(path, "y = 2\n") { :ok }
      assert_equal original, File.binread(path)
    end
  end

  # Simulated hard kill: a mutated file + leftover backup on disk. Startup sweep
  # restores the original and removes the backup, with a one-line notice.
  def test_restore_orphans_heals_a_left_mutated_file
    with_file("mutated-leftover\n") do |dir, path|
      File.binwrite(path + Mutineer::FileSwap::BACKUP_SUFFIX, "original\n")
      out, err = capture_io { Mutineer::FileSwap.restore_orphans([dir]) }
      assert_equal "original\n", File.binread(path)
      assert_empty Dir.glob(File.join(dir, "*#{Mutineer::FileSwap::BACKUP_SUFFIX}"))
      assert_empty out
      assert_match(/restored 1/, err)
    end
  end

  def test_restore_orphans_noop_when_none
    with_file("original\n") do |dir, _path|
      out, err = capture_io { Mutineer::FileSwap.restore_orphans([dir]) }
      assert_empty out
      assert_empty err
    end
  end

  # A leftover backup with no live owner is the original, not a concurrent run.
  # Restore from it, then swap, then put those bytes back.
  def test_with_uses_orphan_backup_as_original
    with_file("mutated-leftover\n") do |_dir, path|
      File.binwrite(path + Mutineer::FileSwap::BACKUP_SUFFIX, "true-original\n")
      seen = nil
      Mutineer::FileSwap.with(path, "new-mutant\n") { seen = File.binread(path) }
      assert_equal "new-mutant\n", seen
      assert_equal "true-original\n", File.binread(path)
    end
  end

  # #99: restore_orphans must not consume a live owner's backup or mutant.
  def test_restore_orphans_leaves_live_owner_intact
    with_file("original") do |dir, path|
      rd_ready, wr_ready = IO.pipe
      rd_resume, wr_resume = IO.pipe
      pid = fork do
        rd_ready.close
        wr_resume.close
        Mutineer::FileSwap.with(path, "mutant") do
          wr_ready.write("1")
          wr_ready.close
          rd_resume.read(1)
          File.binwrite(File.join(dir, "observed"), File.binread(path))
        end
        exit! 0
      end
      wr_ready.close
      rd_resume.close
      rd_ready.read(1)
      capture_io { Mutineer::FileSwap.restore_orphans([dir]) }
      backup_kept = File.exist?(path + Mutineer::FileSwap::BACKUP_SUFFIX)
      wr_resume.write("1")
      wr_resume.close
      Process.wait(pid)
      assert_equal "mutant", File.binread(File.join(dir, "observed"))
      assert backup_kept, "live owner must keep its recovery backup"
      assert_equal "original", File.binread(path)
    end
  end

  # #99: a second swap must refuse while another process owns the source.
  def test_with_raises_when_another_process_owns
    with_file("original") do |_dir, path|
      rd_ready, wr_ready = IO.pipe
      rd_resume, wr_resume = IO.pipe
      pid = fork do
        rd_ready.close
        wr_resume.close
        Mutineer::FileSwap.with(path, "mutant") do
          wr_ready.write("1")
          wr_ready.close
          rd_resume.read(1)
        end
        exit! 0
      end
      wr_ready.close
      rd_resume.close
      rd_ready.read(1)
      assert_raises(Mutineer::ConcurrentRunError) do
        Mutineer::FileSwap.with(path, "other") { flunk "block must not run" }
      end
      assert_equal "mutant", File.binread(path)
      wr_resume.write("1")
      wr_resume.close
      Process.wait(pid)
      assert_equal "original", File.binread(path)
    end
  end

  # #99: after the lock owner dies, the next restore heals the exact original.
  def test_restore_orphans_heals_after_owner_dies
    with_file("original") do |dir, path|
      rd_ready, wr_ready = IO.pipe
      pid = fork do
        rd_ready.close
        Mutineer::FileSwap.with(path, "mutant") do
          wr_ready.write("1")
          wr_ready.close
          sleep 30
        end
        exit! 0
      end
      wr_ready.close
      rd_ready.read(1)
      Process.kill("KILL", pid)
      Process.wait(pid)
      assert_equal "mutant", File.binread(path)
      capture_io { Mutineer::FileSwap.restore_orphans([dir]) }
      assert_equal "original", File.binread(path)
      assert_empty Dir.glob(File.join(dir, "*#{Mutineer::FileSwap::BACKUP_SUFFIX}"))
    end
  end

  # A real user file that merely ends in the suffix, with no sibling, is left alone
  # (never used to create a file).
  def test_restore_orphans_ignores_suffixed_file_with_no_sibling
    Dir.mktmpdir("mutineer-swap") do |dir|
      stray = File.join(dir, "notes#{Mutineer::FileSwap::BACKUP_SUFFIX}")
      File.binwrite(stray, "user data\n")
      _out, err = capture_io { Mutineer::FileSwap.restore_orphans([dir]) }
      assert_path_exists stray
      refute_path_exists File.join(dir, "notes")
      assert_empty err
    end
  end

  # A redundant backup identical to the source (crash between restore and unlink)
  # is cleared without a false "healed" notice, so the next run sees no race.
  def test_restore_orphans_clears_stale_identical_backup
    with_file("original\n") do |dir, path|
      File.binwrite(path + Mutineer::FileSwap::BACKUP_SUFFIX, "original\n")
      _out, err = capture_io { Mutineer::FileSwap.restore_orphans([dir]) }
      assert_empty Dir.glob(File.join(dir, "*#{Mutineer::FileSwap::BACKUP_SUFFIX}"))
      assert_equal "original\n", File.binread(path)
      assert_empty err
    end
  end
end
