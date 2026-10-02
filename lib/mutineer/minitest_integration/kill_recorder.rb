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

        # Installs the hooks and arms the recorder for this process.
        #
        # @param channel [IO] the write end of the channel.
        # @return [Boolean] false when the Minitest shape is unknown.
        def arm!(channel)
          outer = OuterReporter.hook_for_loaded_minitest
          return false unless outer

          OuterReporter.prepend_once(::Minitest::CompositeReporter, Record)
          OuterReporter.prepend_once(::Minitest.singleton_class, outer)
          OuterReporter.register(self)
          self.armed_pid = Process.pid
          self.armed_reporter = nil
          self.channel = channel
          true
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
          KillChannel.write(channel, event, Array(result.source_location).first, "#{result.klass}##{result.name}")
        end
      end
    end
  end
end
