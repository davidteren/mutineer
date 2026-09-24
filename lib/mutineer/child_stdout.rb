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
    # Call it only in a child that exits after the tests run. Nothing restores
    # the previous stdout.
    #
    # @return [void]
    def self.silence
      File.open(File::NULL, "w") { |null| STDOUT.reopen(null) }
      $stdout = STDOUT
    end
  end
end
