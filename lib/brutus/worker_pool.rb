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
            # R1: the child must ALWAYS hard-exit. If yield raises, marshal an
            # error Result and exit! in `ensure` — otherwise the child unwinds
            # normally and our Minitest at_exit autorun re-runs the parent suite
            # inside the worker, losing the real error.
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
        running[pid] = [idx, rd]
      end
    end

    # R6: reap exactly one of OUR children. wait2(-1) would reap (steal) any of
    # the host process's children — fatal when the pool runs under a forking test
    # suite. Poll our known pids with WNOHANG instead.
    def reap(results, running)
      return if running.empty?

      loop do
        running.each_key do |pid|
          reaped, = Process.waitpid2(pid, Process::WNOHANG)
          next unless reaped

          return collect(results, running, pid)
        end
        sleep 0.005
      end
    end

    def collect(results, running, pid)
      idx, rd = running.delete(pid)
      data = rd.read
      rd.close
      results[idx] =
        if data.empty?
          Result.error("worker produced no result")
        else
          # R6: a partial/garbage Marshal stream (dead worker) must not crash the
          # pool — degrade to an error Result.
          begin
            Marshal.load(data)
          rescue StandardError => e
            Result.error("worker result unreadable: #{e.class}: #{e.message}")
          end
        end
    end
  end
end
