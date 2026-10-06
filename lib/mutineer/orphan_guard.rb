# frozen_string_literal: true

module Mutineer
  # Ends a forked child's process group once the process that forked it is
  # gone (#101). A mutant or capture child leads its own process group, so a
  # parent that dies, or is killed by a client that gave up on it, does not
  # take the child's tests with it; without this, a hung test would run on and
  # keep its worker database open. Needs no other part of Mutineer, so the
  # app-side daemon can load it.
  module OrphanGuard
    # Seconds between checks. A forked child gets no signal on parent death.
    POLL = 0.5

    # Starts the watchdog in the current (child) process.
    #
    # @param parent [Integer] the parent's pid, read in the parent before
    #   `fork`, so a parent that dies before this call is still noticed.
    # @return [Thread]
    def self.start(parent)
      Thread.new do
        sleep(POLL) while Process.ppid == parent
        # Group 0 only when this child leads its own group: a failed setpgid
        # leaves it in the parent's group, which must not be killed.
        Process.kill(:KILL, Process.getpgrp == Process.pid ? 0 : Process.pid)
      end
    end
  end
end
