# frozen_string_literal: true

require_relative "result"

module Mutineer
  # Fixed-size fork pool (KTD1/KTD2). `run` forks up to `size` children at
  # once; each child runs the block on one work item, marshals its Result to a
  # private pipe, and exits. The parent reaps any finished child with
  # Process.wait2(-1), opening exactly one slot per reap, then refills.
  # Results are returned in the SAME ORDER as `items` regardless of finish
  # order, so verdicts are identical to a serial run (R4) and downstream output
  # is stable.
  #
  # The block is run inside the child via `yield(*items[i])`; whatever it
  # returns (a Result) is the marshaled payload. Per-mutant timeout is handled
  # one level down by Isolation (KTD2) — the pool adds no separate wall clock.
  class WorkerPool
    # Builds a pool.
    #
    # @param size [Integer] desired pool size.
    def initialize(size)
      @size = [size.to_i, 1].max
    end

    # Runs the work items through the pool.
    #
    # @param items [Array<Array>] work items.
    # @param stop_when [Proc, nil] called with each collected Result; when it
    #   returns truthy, no further items are scheduled and the run drains and
    #   returns early (#21 --fail-fast). Unscheduled slots stay nil.
    # @yieldparam item [Array] one work item.
    # @return [Array<Mutineer::Result>] results in input order (nil for any item
    #   left unscheduled by an early stop).
    def run(items, stop_when: nil)
      results  = Array.new(items.size)
      queue    = (0...items.size).to_a
      running  = {} # pid => [index, read_io, buffer]
      stopping = false

      until queue.empty? && running.empty?
        fill(items, queue, running) { |*args| yield(*args) } unless stopping
        result = reap(results, running)
        if !stopping && stop_when && result && stop_when.call(result)
          stopping = true
          queue.clear # schedule no more; let in-flight workers drain
        end
      end

      results
    end

    private

    # R1: the child must ALWAYS hard-exit. If yield raises, marshal an error
    # Result and exit! in `ensure` — otherwise the child unwinds normally and
    # our Minitest at_exit autorun re-runs the parent suite inside the worker,
    # losing the real error.
    def fill(items, queue, running)
      while running.size < @size && !queue.empty?
        idx = queue.shift
        rd, wr = IO.pipe
        rd.binmode # #19: Marshal output is binary — keep the pipe byte-exact
        wr.binmode
        begin
          pid = fork do
            rd.close
            payload =
              begin
                yield(*items[idx])
              rescue Exception => e # rubocop:disable Lint/RescueException
                Result.error("worker crashed: #{e.class}: #{e.message}")
              end
            begin
              wr.write(Marshal.dump(payload))
            rescue StandardError # rubocop:disable Lint/SuppressedException
              # pipe gone; parent will record "no result"
            ensure
              wr.close
              exit!(0)
            end
          end
        rescue Errno::EAGAIN
          # Process table is full. Put the item back and reap before retrying;
          # if nothing is running we cannot make progress, so re-raise.
          rd.close
          wr.close
          raise if running.empty?

          queue.unshift(idx)
          return
        end
        wr.close
        running[pid] = [idx, rd, +""] # idx, read end, accumulated bytes
      end
    end

    # Drain pipes with IO.select and reap a child only on EOF (#4). The old
    # code reaped first and read after — but a child whose payload exceeds the
    # OS pipe buffer (~64KB) blocks on `write` before it can exit, so it was
    # never reaped and the pool deadlocked. Reading concurrently keeps the
    # pipe drained so the child can finish and exit; EOF means it closed its
    # write end (done writing). We waitpid only OUR known pids (R6: never
    # wait2(-1), which would steal the host suite's children).
    def reap(results, running)
      return if running.empty?

      loop do
        rds = running.values.map { |v| v[1] }
        ready, = IO.select(rds, nil, nil)
        ready.each do |rd|
          pid, (idx, _io, buf) = running.find { |_, v| v[1].equal?(rd) }
          chunk = rd.read_nonblock(65_536, exception: false)
          next if chunk == :wait_readable

          if chunk.nil? # EOF: child closed wr; it is done writing and exiting
            rd.close
            Process.waitpid(pid) # reap the now-finished child (no zombie)
            running.delete(pid)
            # Return the collected Result so the caller's stop_when (#21) can see it.
            return results[idx] = decode(buf)
          end
          buf << chunk
        end
      end
    end

    # R6: a partial/garbage Marshal stream (dead worker) must not crash the
    # pool — degrade to an error Result.
    # @param data [String] marshaled payload.
    # @return [Mutineer::Result] decoded result or error result.
    def decode(data)
      return Result.error("worker produced no result") if data.empty?

      Marshal.load(data)
    rescue StandardError => e
      Result.error("worker result unreadable: #{e.class}: #{e.message}")
    end
  end
end
