# frozen_string_literal: true

require "digest"
require "fileutils"

module Mutineer
  # Raised when another process already holds exclusive ownership of a source
  # file. Aborting beats silently restoring (or capturing) the other run's mutant.
  class ConcurrentRunError < StandardError
    def initialize(path)
      super("another mutineer run owns #{path} — aborting to avoid corrupting the source file.")
    end
  end

  # Apply one whole-file mutant to the REAL source path for the external
  # (`--test-command`) backend, and guarantee the original is restored on every
  # exit path. A separate `bundle exec` subprocess has its own VM and cannot see
  # an in-process `load`, so the mutant must live on disk while its suite runs,
  # which makes leaving the file mutated the one genuinely dangerous failure mode.
  #
  # Defense in depth, mirroring the tempfile-orphan discipline
  # (`Runner.sweep_orphans`, `isolation.rb` tempfiles):
  #   - exclusive OS ownership (flock) is acquired before swap or recovery;
  #   - the original bytes are held in memory AND written to a sibling backup;
  #   - `ensure` restores from memory around every mutant;
  #   - the backup survives a SIGKILL (which skips `ensure`), so `restore_orphans`
  #     can self-heal a left-mutated tree on the next run's startup once the
  #     kernel has released the dead owner's lock.
  # Only one mutant is in flight per file at a time (the external path is serial),
  # so backups never collide.
  module FileSwap
    # Suffix for the on-disk backup; fixed so `restore_orphans` finds it.
    BACKUP_SUFFIX = ".mutineer-backup"

    # Subdirectory under `lock_dir` (or beside the source) that holds flock files.
    LOCK_DIR_NAME = "file-swap-locks"

    # Canonical source path => open lock File held by this process.
    # @api private
    OWNED = {}

    # Real path when the file exists, otherwise `File.expand_path`. Symlink
    # aliases of one inode share this identity for locks, backups, and ownership.
    #
    # @param path [String] source path, relative or absolute.
    # @return [String] canonical absolute path.
    def self.canonical_path(path)
      expanded = File.expand_path(path)
      File.exist?(expanded) ? File.realpath(expanded) : expanded
    end

    # Holds exclusive OS ownership of each source path for the duration of the
    # block. Re-entrant for paths this process already owns. Raises
    # {ConcurrentRunError} when another process holds a path (non-blocking).
    #
    # @param paths [Array<String>] source file paths to own.
    # @param lock_dir [String, nil] directory for flock files (ignored cache).
    # @yield the block to run while ownership is held.
    # @return [Object] the block's return value.
    def self.owning(paths, lock_dir: nil)
      acquired = []
      Array(paths).map { |p| canonical_path(p) }.uniq.sort.each do |path|
        next if OWNED.key?(path)

        acquire!(path, lock_dir: lock_dir)
        acquired << path
      end
      yield
    ensure
      acquired.reverse_each { |path| release!(path) }
    end

    # Writes `mutated` to `source_file`, yields, then restores the original bytes
    # on every exit path (normal return, exception, or `ensure`). Byte-exact:
    # binary read/write preserves encoding, newlines, and trailing bytes.
    # Acquires exclusive ownership first; a leftover backup with no live owner is
    # treated as the original (a prior hard-killed run), not a concurrent run.
    #
    # @param source_file [String] path to the real source file.
    # @param mutated [String] mutated source text to write for the duration.
    # @param lock_dir [String, nil] flock directory shared with {owning}.
    # @yield the block to run while the mutant is on disk.
    # @return [Object] the block's return value.
    def self.with(source_file, mutated, lock_dir: nil)
      path = canonical_path(source_file)
      created = false
      original = nil
      backup = path + BACKUP_SUFFIX
      owning([path], lock_dir: lock_dir) do
        begin
          original = File.exist?(backup) ? File.binread(backup) : File.binread(path)
          File.binwrite(backup, original)
          created = true
          File.binwrite(path, mutated)
          yield
        ensure
          if created
            File.binwrite(path, original)
            File.unlink(backup) if File.exist?(backup)
          end
        end
      end
    end

    # Startup/after-run self-heal: restore any source file left mutated by a prior
    # interrupted run (a leftover `*.mutineer-backup`), then remove the backup.
    # Skips a backup whose source is owned by a live process. Prints one line to
    # stderr when it actually heals something, so a developer knows their working
    # tree was auto-restored (a file they did not touch).
    #
    # @param dirs [Array<String>] directories to sweep for orphaned backups.
    # @param lock_dir [String, nil] flock directory shared with {owning}.
    # @return [void]
    def self.restore_orphans(dirs, lock_dir: nil)
      healed = 0
      dirs.uniq.each do |dir|
        Dir.glob(File.join(dir, "*#{BACKUP_SUFFIX}")).each do |backup|
          source_file = backup.delete_suffix(BACKUP_SUFFIX)
          begin
            owning([source_file], lock_dir: lock_dir) { healed += restore_one(backup, source_file) }
          rescue ConcurrentRunError
            next
          end
        end
      end
      return if healed.zero?

      warn "[mutineer] restored #{healed} source file(s) left mutated by a previous interrupted run."
    end

    # Exclusive non-blocking flock for canonical `path`.
    #
    # @api private
    # @param path [String] canonical source path.
    # @param lock_dir [String, nil] directory for the flock file.
    # @return [void]
    # @raise [Mutineer::ConcurrentRunError] when the lock is held elsewhere.
    def self.acquire!(path, lock_dir: nil)
      file = File.open(lock_file(path, lock_dir), File::RDWR | File::CREAT, 0o644)
      unless file.flock(File::LOCK_EX | File::LOCK_NB)
        file.close
        raise ConcurrentRunError, path
      end
      OWNED[path] = file
    end

    # Flock path for a canonical source. Defaults beside the source under
    # `.mutineer/file-swap-locks` so tmpdir tests clean up with the fixture.
    #
    # @api private
    # @param path [String] canonical source path.
    # @param lock_dir [String, nil] override directory (project cache).
    # @return [String] lock file path.
    def self.lock_file(path, lock_dir)
      dir = lock_dir || File.join(File.dirname(path), ".mutineer", LOCK_DIR_NAME)
      FileUtils.mkdir_p(dir)
      File.join(dir, Digest::SHA256.hexdigest(path))
    end

    # Releases a lock acquired by {acquire!}.
    #
    # @api private
    # @param path [String] expanded source path.
    # @return [void]
    def self.release!(path)
      file = OWNED.delete(path)
      return unless file

      file.flock(File::LOCK_UN)
      file.close
    rescue StandardError
      nil
    end

    # Restores one backup if the sibling source exists. Returns 1 when bytes
    # were written back, 0 when the backup was redundant or had no sibling.
    #
    # @api private
    # @param backup [String] path to the `*.mutineer-backup` file.
    # @param source_file [String] corresponding source path.
    # @return [Integer] 1 if healed, otherwise 0.
    def self.restore_one(backup, source_file)
      return 0 unless File.exist?(source_file)

      backup_bytes = File.binread(backup)
      if File.binread(source_file) == backup_bytes
        File.unlink(backup)
        0
      else
        File.binwrite(source_file, backup_bytes)
        File.unlink(backup)
        1
      end
    end
  end
end
