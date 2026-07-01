# frozen_string_literal: true

module Mutineer
  # #27 (U2): apply one whole-file mutant to the REAL source path for the external
  # (`--test-command`) backend, and guarantee the original is restored on every
  # exit path. A separate `bundle exec` subprocess has its own VM and cannot see an
  # in-process `load`, so the mutant must live on disk while its suite runs — which
  # makes leaving the file mutated the one genuinely dangerous failure mode.
  #
  # Defense in depth, mirroring the tempfile-orphan discipline
  # (`Runner.sweep_orphans`, `isolation.rb` tempfiles):
  #   - the original bytes are held in memory AND written to a sibling backup;
  #   - `ensure` restores from memory around every mutant;
  #   - the backup survives a SIGKILL (which skips `ensure`), so `restore_orphans`
  #     can self-heal a left-mutated tree on the next run's startup.
  # Only one mutant is in flight per file at a time (the external path is serial),
  # so backups never collide.
  module FileSwap
    # Suffix for the on-disk backup; fixed so `restore_orphans` finds it.
    BACKUP_SUFFIX = ".mutineer-backup"

    # Writes `mutated` to `source_file`, yields, then restores the original bytes
    # on every exit path (normal return, exception, or `ensure`). Byte-exact:
    # binary read/write preserves encoding, newlines, and trailing bytes.
    #
    # @param source_file [String] path to the real source file.
    # @param mutated [String] mutated source text to write for the duration.
    # @yield the block to run while the mutant is on disk.
    # @return [Object] the block's return value.
    def self.with(source_file, mutated)
      original = File.binread(source_file)
      backup   = source_file + BACKUP_SUFFIX
      File.binwrite(backup, original)
      File.binwrite(source_file, mutated)
      yield
    ensure
      File.binwrite(source_file, original) if original
      File.unlink(backup) if backup && File.exist?(backup)
    end

    # Startup/after-run self-heal: restore any source file left mutated by a prior
    # interrupted run (a leftover `*.mutineer-backup`), then remove the backup.
    # Prints one line to stderr when it actually heals something, so a developer
    # knows their working tree was auto-restored (a file they did not touch).
    #
    # @param dirs [Array<String>] directories to sweep for orphaned backups.
    # @return [void]
    def self.restore_orphans(dirs)
      healed = 0
      dirs.uniq.each do |dir|
        Dir.glob(File.join(dir, "*#{BACKUP_SUFFIX}")).each do |backup|
          source_file = backup.delete_suffix(BACKUP_SUFFIX)
          File.binwrite(source_file, File.binread(backup))
          File.unlink(backup)
          healed += 1
        end
      end
      return if healed.zero?

      warn "[mutineer] restored #{healed} source file(s) left mutated by a previous interrupted run."
    end
  end
end
