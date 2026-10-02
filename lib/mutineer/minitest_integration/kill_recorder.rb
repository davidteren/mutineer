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

        # Installs the hooks, arms the recorder for this process, and writes the
        # channel's `start` line. Call it after the test files load, so the line
        # can say whether a test class runs in parallel. An unknown Minitest
        # shape arms nothing and writes nothing, so the parent sees no `start`
        # and keeps the row incomplete.
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
          KillChannel.write_start(channel, parallel: parallel?(runnables))
          true
        end

        # Writes the channel's `end` line once the suite has returned normally.
        # Does nothing unless the recorder is armed in this process.
        #
        # @return [void]
        def finish!
          KillChannel.write_end(channel) if channel && armed_here?
        end

        # True when some test class runs its tests in parallel threads
        # (`parallelize_me!`). The stop at the first failure cannot skip those,
        # since they are all queued before the first one fails. Minitest 6 names
        # the order `run_order`; Minitest 5 names it `test_order`.
        #
        # @param runnables [Array<Class>] the loaded test classes.
        # @return [Boolean]
        def parallel?(runnables)
          runnables.any? do |klass|
            %i[run_order test_order].any? { |order| klass.respond_to?(order) && klass.public_send(order) == :parallel }
          end
        end

        # Clears the armed state.
        #
        # @return [void]
        def disarm!
          self.armed_pid = nil
          self.armed_reporter = nil
          self.channel = nil
        end

        # Sends one result recorded on `reporter`: a pass, or a kill for a
        # failure or an error. Skips and results on other reporters send
        # nothing.
        #
        # @param reporter [Minitest::CompositeReporter] the recording reporter.
        # @param result [Minitest::Result] the result of one test.
        # @return [void]
        def record(reporter, result)
          return if result.skipped?
          return unless channel && outer_reporter?(reporter)

          event = result.passed? ? KillChannel::PASS : KillChannel::KILL
          # `Class#method` is unique within a run, so the name is also the id.
          KillChannel.write(channel, event, Array(result.source_location).first, "#{result.klass}##{result.name}")
        end
      end
    end
  end
end
