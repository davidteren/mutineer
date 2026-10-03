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
        status = with_fail_fast_off(record_to) do
          ::RSpec::Core::Runner.run([*args, *Array(spec_files)], sink, sink)
        end
        # Reached only when the suite returned: an example that exits the
        # process skips it, and the parent then keeps the row incomplete.
        KillChannel.write_end(record_to) if record_to

        status.zero? ? 0 : 1
      end

      # Runs the block with fail-fast forced off when `record_to` is set: a
      # matrix run must run every example. RSpec reads options from .rspec, then
      # the command line, then `SPEC_OPTS`, and the last one wins, so the option
      # goes at the end of `SPEC_OPTS` (restored afterwards). A forced option
      # also beats `config.fail_fast = true` in a spec helper.
      #
      # @api private
      # @param record_to [IO, nil] the channel of a matrix run, or nil.
      # @yieldreturn [Integer] RSpec's exit status.
      # @return [Integer] the block's value.
      def self.with_fail_fast_off(record_to)
        return yield unless record_to

        saved = ENV.fetch("SPEC_OPTS", nil)
        ENV["SPEC_OPTS"] = [saved, "--no-fail-fast"].compact.join(" ")
        begin
          yield
        ensure
          ENV["SPEC_OPTS"] = saved
        end
      end

      # Sends each example's outcome to the channel of a `--matrix` run. A
      # pending or skipped example sends nothing. A test is its spec file, its
      # full description (the name reports show) and its example id, which
      # tells apart examples that share a description and stays the same when a
      # mutant changes a generated description. RSpec before 3.3 has no example
      # id, so there the id is the example's location.
      #
      # It writes only from the process that created it, so an example that runs
      # an RSpec suite in a forked process cannot add lines. It writes `start`
      # when the run begins with fail-fast off; a run that could stop early sends
      # no `start`, and its rows stay incomplete. It also registers an
      # `after(:suite)` hook that writes `cleanup` ahead of the suite's own hooks.
      class KillFormatter
        # Registers the formatter with RSpec for the notifications it handles.
        # Called at run time, because rspec-core is not loaded with Mutineer.
        #
        # @return [Class] this class.
        def self.registered
          ::RSpec::Core::Formatters.register(self, :start, :example_passed, :example_failed)
          self
        end

        # @param channel [IO] the write end of the channel.
        def initialize(channel)
          @channel = channel
          @pid = Process.pid
        end

        # Sends `start`, unless fail-fast is on, and registers the hook that
        # sends `cleanup`. RSpec runs `after(:suite)` hooks last-defined first,
        # and this runs once the spec files have loaded, so the hook goes before
        # every hook the suite defines.
        #
        # @param _notification [RSpec::Core::Notifications::StartNotification]
        # @return [void]
        def start(_notification)
          return unless owner?
          return if ::RSpec.configuration.fail_fast

          KillChannel.write_start(@channel)
          formatter = self
          ::RSpec.configuration.after(:suite) { formatter.cleanup_begins }
        end

        # Sends `cleanup`: every example has run, and the suite's own hooks follow.
        #
        # @return [void]
        def cleanup_begins
          KillChannel.write_cleanup(@channel) if owner?
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

        # True in the process that created the formatter.
        #
        # @return [Boolean]
        def owner?
          Process.pid == @pid
        end

        # Writes one test line for `example`.
        #
        # @param event [String] {KillChannel::PASS} or {KillChannel::KILL}.
        # @param example [RSpec::Core::Example] the example.
        # @return [void]
        def send_event(event, example)
          return unless owner?

          file = example.metadata[:absolute_file_path] || File.expand_path(example.file_path)
          KillChannel.write(@channel, event, file, example.full_description, identify(example))
        rescue StandardError
          # A recorder that raised would change the verdict; the lost line keeps the row incomplete.
          KillChannel.write_lost(@channel)
        end

        # What tells `example` apart from the others, and stays the same across
        # mutants: its id, or its location before RSpec 3.3.
        #
        # @param example [RSpec::Core::Example] the example.
        # @return [String]
        def identify(example)
          example.respond_to?(:id) ? example.id : example.metadata.fetch(:location)
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
