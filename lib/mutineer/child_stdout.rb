# frozen_string_literal: true

module Mutineer
  # Silences stdout in a forked child that runs tests. Every fork boundary
  # calls {.silence} once, right after `fork`, so the test runners themselves
  # do not touch stdout. The parent reads each child's result from a separate
  # pipe or from the exit status, never from stdout.
  #
  # Stderr stays open: it carries mutineer's own diagnostics from the child.
  #
  # Stdlib-only, so the app-side daemon can load it.
  module ChildStdout
    # Points fd 1 at File::NULL and makes `$stdout` the real STDOUT again.
    #
    # The reopen goes through STDOUT, not `$stdout`: the parent may have left
    # `$stdout` as a StringIO, which cannot reopen. A test that calls
    # `$stdout.reopen` (Minitest's `capture_subprocess_io`, RSpec's
    # `to_stdout_from_any_process`) then gets a real IO. Child processes of the
    # test inherit the silenced fd 1 too.
    #
    # The reopen takes an open IO, not a path. A path reopen checks the access
    # mode of STDOUT and raises ArgumentError when a parent left STDOUT on a
    # file in another mode (for example the "w+x" Tempfile of Minitest's
    # `capture_subprocess_io`).
    #
    # The null device is binary. A text-mode one still transcodes writes to
    # `Encoding.default_external` once `Encoding.default_internal` is set too.
    # Rails sets both to UTF-8 (`config.encoding`). The reporter's print of a
    # failure message that holds raw bytes (what `assert_response` does with a
    # short body) then raises `Encoding::UndefinedConversionError`, after the
    # test has already failed. The child's rescue scores that `error`, not
    # `killed` (#434). Nothing reads the silenced bytes.
    #
    # Call it only in a child that exits after the tests run. Nothing restores
    # the previous stdout.
    #
    # @return [void]
    def self.silence
      File.open(File::NULL, "wb") { |null| STDOUT.reopen(null) }
      # `reopen` can keep a UTF-8 encoding the process already had. Binary
      # mode drops it, so a later write of those bytes cannot raise.
      STDOUT.binmode
      $stdout = STDOUT
    end
  end
end
