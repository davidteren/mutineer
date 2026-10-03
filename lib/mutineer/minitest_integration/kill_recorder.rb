# frozen_string_literal: true

require_relative "outer_reporter"
require_relative "../kill_channel"

module Mutineer
  class MinitestIntegration
    # Sends the outcome of each test to the parent of a `--matrix` mutant run,
    # through {KillChannel}. It never stops the run: every covering test runs,
    # so the parent learns exactly which tests kill the mutant. Child-process
    # only, like MinitestIntegration.
    #
    # Only the outer reporter counts (see {OuterReporter}): a test can build and
    # record on its own reporter, and those results are not the run's.
    module KillRecorder
      extend OuterReporter::Client

      # Serializes the counting and the writing of results, which Minitest
      # records from several threads in a parallel class.
      LOCK = Mutex.new

      # Prepended on `Minitest::CompositeReporter`.
      module Record
        # Records the result, then sends it to the channel.
        #
        # @param result [Minitest::Result] the result of one test.
        # @return [void]
        def record(result)
          super
          KillRecorder.record(self, result)
        end
      end

      class << self
        # The write end of the channel of the armed run.
        #
        # @return [IO, nil]
        attr_accessor :channel

        # Names of the loaded test classes that run in parallel.
        #
        # @return [Array<String>, nil]
        attr_accessor :parallel_classes

        # True once the `parallel` line has gone out.
        #
        # @return [Boolean, nil]
        attr_accessor :parallel_marked

        # The loaded test classes of the armed run.
        #
        # @return [Array<Class>, nil]
        attr_accessor :runnables

        # How many results the outer reporter has recorded, skips included.
        #
        # @return [Integer, nil]
        attr_accessor :seen

        # Installs the hooks, arms the recorder for this process, and writes the
        # channel's `start` line. Call it after the test files load, so the
        # recorder knows the test classes. An unknown Minitest shape arms
        # nothing and writes nothing, so the parent sees no `start` and keeps
        # the row incomplete.
        #
        # @param channel [IO] the write end of the channel.
        # @param runnables [Array<Class>] the loaded test classes.
        # @return [Boolean] false when the Minitest shape is unknown.
        def arm!(channel, runnables)
          outer = OuterReporter.hook_for_loaded_minitest
          return false unless outer

          OuterReporter.prepend_once(::Minitest::CompositeReporter, Record)
          OuterReporter.prepend_once(::Minitest.singleton_class, outer)
          OuterReporter.register(self)
          self.armed_pid = Process.pid
          self.armed_reporter = nil
          self.channel = channel
          self.parallel_classes = runnables.select { |klass| parallel?(klass) }.map(&:to_s)
          self.parallel_marked = false
          self.runnables = runnables
          self.seen = 0
          KillChannel.write_start(channel)
          true
        end

        # Writes the channel's `end` line once the suite has returned and the
        # outer reporter has seen every test the loaded classes run. A return
        # alone proves nothing: Minitest catches an Interrupt in a test and
        # returns after the tests so far. Does nothing unless the recorder is
        # armed in this process.
        #
        # @return [void]
        def finish!
          return unless channel && armed_here?

          KillChannel.write_end(channel) if seen == planned_tests
        end

        # True when the test class runs its tests in parallel threads
        # (`parallelize_me!`). Minitest runs these after every serial class, and
        # the stop at the first failure cannot skip the tests it already queued.
        # Minitest 6 names the order `run_order`; Minitest 5 names it `test_order`.
        #
        # @param klass [Class] a loaded test class.
        # @return [Boolean]
        def parallel?(klass)
          %i[run_order test_order].any? { |order| klass.respond_to?(order) && klass.public_send(order) == :parallel }
        end

        # Clears the armed state.
        #
        # @return [void]
        def disarm!
          self.armed_pid = nil
          self.armed_reporter = nil
          self.channel = nil
          self.parallel_classes = nil
          self.runnables = nil
        end

        # Sends one result recorded on `reporter`: a pass, or a kill for a
        # failure or an error. Skips send no test line, though they count as
        # seen, and results on other reporters count for nothing. The
        # `parallel` line goes out before the first result of a parallel class,
        # so a kill that precedes it came from a serial test.
        #
        # @param reporter [Minitest::CompositeReporter] the recording reporter.
        # @param result [Minitest::Result] the result of one test.
        # @return [void]
        def record(reporter, result)
          return unless channel && outer_reporter?(reporter)

          LOCK.synchronize do
            self.seen += 1
            mark_parallel if parallel_classes.include?(result.klass.to_s)
            next if result.skipped?

            event = result.passed? ? KillChannel::PASS : KillChannel::KILL
            # `Class#method` is unique within a run, so the name is also the id.
            KillChannel.write(channel, event, Array(result.source_location).first, "#{result.klass}##{result.name}")
          end
        end

        private

        # Writes the `parallel` line, once.
        #
        # @return [void]
        def mark_parallel
          return if parallel_marked

          self.parallel_marked = true
          KillChannel.write_parallel(channel)
        end

        # How many tests the loaded classes ran, or nil when it cannot be told.
        # Asked after the run, because `runnable_methods` shuffles with the
        # seed that `Minitest.run` sets.
        #
        # @return [Integer, nil]
        def planned_tests
          runnables.sum { |klass| klass.runnable_methods.size }
        rescue StandardError
          nil
        end
      end
    end
  end
end
