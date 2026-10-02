# frozen_string_literal: true

require "stringio"
require_relative "../kill_channel"

module Mutineer
  # Raised when the target project asks for a framework whose gem isn't present.
  # rspec is NOT a Mutineer dependency — it must come from the project's bundle.
  class FrameworkUnavailable < StandardError; end

  module TestRunners
    # Child-process-only RSpec runner.
    #
    # Mirrors MinitestIntegration's contract: run the given spec files and
    # return 0 (all passed) or 1 (any failure).
    module RSpec
      # Runs the given RSpec files.
      #
      # @param spec_files [String, Array<String>] one file or many files.
      # @param stop_at_first_failure [Boolean] when true, the run ends at the
      #   first failing example (RSpec `--fail-fast`).
      # @param record_to [IO, nil] a `--matrix` run: send each example's outcome
      #   to this channel (see {KillFormatter}) and run every example.
      # @return [Integer] 0 on success, 1 on failure.
      # @raise [ArgumentError] when both options are given: a matrix run never stops.
      def self.run(spec_files, stop_at_first_failure: false, record_to: nil)
        if stop_at_first_failure && record_to
          raise ArgumentError, "stop_at_first_failure and record_to cannot be combined: a matrix run runs every example"
        end

        require_rspec!

        ::RSpec::Core::Runner.disable_autorun!
        ::RSpec.reset
        # Added before the run reads its options, which leaves the reporter
        # unbuilt, so the run's output stream still applies. With a formatter
        # present, RSpec adds no default one; its output went to the sink anyway.
        ::RSpec.configuration.add_formatter(KillFormatter.registered, record_to) if record_to

        # The sink takes RSpec's own formatter output. Spec output is not
        # silenced here: the fork boundary that calls this method has already
        # pointed stdout at File::NULL (see ChildStdout).
        sink = StringIO.new
        args = ["--no-color"]
        args << "--fail-fast" if stop_at_first_failure
        # A project's .rspec can turn fail-fast on; a matrix run must still run
        # every example, and a command-line option wins over .rspec.
        args << "--no-fail-fast" if record_to
        status = ::RSpec::Core::Runner.run([*args, *Array(spec_files)], sink, sink)

        status.zero? ? 0 : 1
      end

      # Sends each example's outcome to the channel of a `--matrix` run. A
      # pending or skipped example sends nothing. The test's identity is its
      # spec file and full description.
      class KillFormatter
        # Registers the formatter with RSpec for the notifications it handles.
        # Called at run time, because rspec-core is not loaded with Mutineer.
        #
        # @return [Class] this class.
        def self.registered
          ::RSpec::Core::Formatters.register(self, :example_passed, :example_failed)
          self
        end

        # @param channel [IO] the write end of the channel.
        def initialize(channel)
          @channel = channel
        end

        # Sends a pass.
        #
        # @param notification [RSpec::Core::Notifications::ExampleNotification]
        # @return [void]
        def example_passed(notification)
          send_event(KillChannel::PASS, notification.example)
        end

        # Sends a kill.
        #
        # @param notification [RSpec::Core::Notifications::FailedExampleNotification]
        # @return [void]
        def example_failed(notification)
          send_event(KillChannel::KILL, notification.example)
        end

        private

        # Writes one event for `example`.
        #
        # @param event [String] {KillChannel::PASS} or {KillChannel::KILL}.
        # @param example [RSpec::Core::Example] the example.
        # @return [void]
        def send_event(event, example)
          file = example.metadata[:absolute_file_path] || File.expand_path(example.file_path)
          KillChannel.write(@channel, event, file, example.full_description)
        end
      end

      # Requires rspec-core from the project under test.
      #
      # @api private
      def self.require_rspec!
        require "rspec/core"
      rescue LoadError
        raise Mutineer::FrameworkUnavailable,
              "framework 'rspec' requested but rspec is not available; " \
              "add rspec to the project under test (its bundle), then retry"
      end
    end
  end
end
