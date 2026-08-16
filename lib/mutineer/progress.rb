# frozen_string_literal: true

module Mutineer
  # Coarse run progress on stderr: one line per 10% step of completed mutants
  # (which means every completion on a run smaller than ten). Shared by every
  # backend so a long run is never silent between config resolution and the
  # report. Thread-safe so the daemon's parallel workers can share one instance.
  # Writes only to stderr, keeping `--format json` stdout and `--output` files
  # byte-exact per the Reporter's stream contract.
  class Progress
    # Builds a progress counter for a run of `total` mutants.
    #
    # @param total [Integer] number of mutants that will run.
    # @param io [IO] destination stream (defaults to stderr; injectable for tests).
    def initialize(total, io: $stderr)
      @total = total
      @done = 0
      @last_step = 0
      @mutex = Mutex.new
      @io = io
    end

    # Records one completed mutant and prints when a 10% boundary is crossed.
    # A zero-total counter never prints (guards the division, and an empty run
    # has nothing to report).
    #
    # @return [void]
    def tick
      @mutex.synchronize do
        return if @total.zero?

        @done += 1
        step = (@done * 10) / @total
        return if step <= @last_step

        @last_step = step
        @io.puts "[mutineer] #{@done}/#{@total} mutants (#{(@done * 100) / @total}%)"
      end
    rescue IOError, Errno::EPIPE
      # Progress is best-effort: a closed stderr (piped consumer went away) must
      # never kill the run — in the daemon's worker threads a raise here would
      # propagate through Thread#join and abort scoring.
      nil
    end
  end
end
