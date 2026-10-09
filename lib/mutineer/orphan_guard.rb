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
    # `Tempfile.create(["mutineer_daemon", ".rb"])` names the file
    # `mutineer_daemon<YYYYMMDD>-<pid>-<rand>.rb`. The pid is the child that
    # is loading the mutant.
    DAEMON_TEMP_PID = /\Amutineer_daemon\d{8}-(\d+)-/

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

    # True when a daemon mutant file still belongs to a live process. A boot
    # sweep must leave it alone. The database lock is taken later, so the
    # sweep is the step that used to delete another run's file.
    #
    # The creating pid is in the file name. A process that still holds the
    # file lock counts too, even when that pid is already gone. A dead pid
    # and a free lock is an orphan a killed child left behind.
    #
    # @param path [String] absolute path of a `mutineer_daemon*.rb` file.
    # @return [Boolean]
    def self.mutant_file_in_use?(path)
      creator_alive?(path) || locked_by_another?(path)
    end

    # True when the pid embedded in a daemon mutant file name is still running.
    # Pid 0 is this process group, so it is never treated as an owner.
    #
    # @param path [String]
    # @return [Boolean]
    def self.creator_alive?(path)
      pid_text = File.basename(path)[DAEMON_TEMP_PID, 1]
      return false unless pid_text

      pid = Integer(pid_text, 10)
      return false if pid <= 0

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EINVAL, RangeError
      false
    rescue SystemCallError
      true
    end

    # True when another process holds an exclusive lock on `path`. A lock the
    # kernel rejects as unsupported is not ownership: the pid check still applies.
    # A file we cannot inspect is left in place.
    #
    # @param path [String]
    # @return [Boolean]
    def self.locked_by_another?(path)
      File.open(path, File::RDONLY) do |file|
        file.flock(File::LOCK_EX | File::LOCK_NB) == false
      end
    rescue Errno::ENOENT, Errno::ENOTSUP, Errno::EOPNOTSUPP
      false
    rescue SystemCallError
      true
    end
    private_class_method :creator_alive?, :locked_by_another?
  end
end
