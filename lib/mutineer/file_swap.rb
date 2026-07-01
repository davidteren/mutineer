# frozen_string_literal: true

module Mutineer
  # Raised when a source file's backup already exists as FileSwap.with begins —
  # a second mutineer run is racing on the same file (the backup path is shared
  # and unlocked). Aborting beats silently leaving the tree mutated.
  class ConcurrentRunError < StandardError
    def initialize(backup)
      super("a backup already exists at #{backup} — is another mutineer run active " \
            "in this directory? Aborting to avoid corrupting the source file.")
    end
  end

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
      backup = source_file + BACKUP_SUFFIX
      # A backup already on disk means either a prior hard-killed run (restore_orphans
      # should have healed it at startup) or a SECOND mutineer run racing us on the
      # same file. The backup path is shared and unlocked, so proceeding would let
      # us capture the other run's mutant AS the "original" and permanently mutate
      # the tree. Refuse loudly rather than silently corrupt — and do it BEFORE
      # `created` is set, so the ensure below never touches a backup we don't own.
      raise ConcurrentRunError, backup if File.exist?(backup)

      original = File.binread(source_file)
      File.binwrite(backup, original)
      created = true
      File.binwrite(source_file, mutated)
      yield
    ensure
      if created
        File.binwrite(source_file, original)
        File.unlink(backup) if File.exist?(backup)
      end
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
          backup_bytes = File.binread(backup)
          if !File.exist?(source_file)
            # A real user file that merely ends in our suffix, with no sibling to
            # restore — leave it untouched (never create a file from it).
            next
          elsif File.binread(source_file) == backup_bytes
            # Redundant backup (e.g. a crash between restore and unlink): nothing to
            # heal, just clear the orphan so the next run doesn't see a false race.
            File.unlink(backup)
          else
            File.binwrite(source_file, backup_bytes)
            File.unlink(backup)
            healed += 1
          end
        end
      end
      return if healed.zero?

      warn "[mutineer] restored #{healed} source file(s) left mutated by a previous interrupted run."
    end
  end
end
