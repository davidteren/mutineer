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
end
