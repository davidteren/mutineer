# frozen_string_literal: true

require_relative "result"

module Brutus
  # Fixed-size fork pool (KTD1/KTD2). `run` forks up to `size` children at once;
  # each child runs the block on one work item, marshals its Result to a private
  # pipe, and exits. The parent reaps any finished child with Process.wait2(-1),
  # opening exactly one slot per reap, then refills. Results are returned in the
  # SAME ORDER as `items` regardless of finish order, so verdicts are identical to
  # a serial run (R4) and downstream output is stable.
  #
  # The block is evaluated inside the child via `yield(*items[i])`; whatever it
  # returns (a Result) is the marshaled payload. Per-mutant timeout is handled one
  # level down by Isolation (KTD2) — the pool adds no separate wall clock.
  class WorkerPool
    def initialize(size)
      @size = [size.to_i, 1].max
    end

    def run(items)
      results = Array.new(items.size)
      queue   = (0...items.size).to_a
      running = {} # pid => [index, read_io]

      until queue.empty? && running.empty?
        fill(items, queue, running) { |*args| yield(*args) }
        reap(results, running)
      end

      results
    end

    private

    def fill(items, queue, running)
      while running.size < @size && !queue.empty?
        idx = queue.shift
        rd, wr = IO.pipe
        begin
          pid = fork do
            rd.close
            payload = yield(*items[idx])
            wr.write(Marshal.dump(payload))
            wr.close
            exit!(0)
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
        running[pid] = [idx, rd]
      end
    end

    def reap(results, running)
      return if running.empty?

      pid, = Process.wait2(-1)
      slot = running.delete(pid)
      return unless slot # a child not started by us

      idx, rd = slot
      data = rd.read
      rd.close
      results[idx] = data.empty? ? Result.error("worker produced no result") : Marshal.load(data)
    end
  end
end
