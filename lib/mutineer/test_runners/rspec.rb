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
    # return 0 (all passed), 1 (an example failed) or 2 (only an error
    # outside examples, such as a spec file that raised while loading).
    module RSpec
      # Runs the given RSpec files.
      #
      # @param spec_files [String, Array<String>] one file or many files.
      # @param stop_at_first_failure [Boolean] when true, the run ends at the
      #   first failing example (RSpec `--fail-fast`).
      # @param record_to [IO, nil] a `--matrix` run: send each example's outcome
      #   to this channel (see {KillFormatter}) and run every example.
      # @return [Integer] 0 on success, else {.failure_code}.
      # @raise [ArgumentError] when both options are given: a matrix run never stops.
      def self.run(spec_files, stop_at_first_failure: false, record_to: nil)
        if stop_at_first_failure && record_to
          raise ArgumentError, "stop_at_first_failure and record_to cannot be combined: a matrix run runs every example"
        end

        require_rspec!

        ::RSpec::Core::Runner.disable_autorun!
        # Not RSpec.reset: it also drops the settings that gems added when Bundler
        # required them, such as rspec-retry's verbose_retry.
        ::RSpec.clear_examples
        # Added before the run reads its options, which leaves the reporter
        # unbuilt, so the run's output stream still applies. With a formatter
        # present, RSpec adds no default one; its output went to the sink anyway.
        KillFormatter.last = nil
        ::RSpec.configuration.add_formatter(KillFormatter.registered, record_to) if record_to

        # The sink takes RSpec's own formatter output. Spec output is not
        # silenced here: the fork boundary that calls this method has already
        # pointed stdout at File::NULL (see ChildStdout).
        sink = StringIO.new
        keep_file_order(spec_files) if stop_at_first_failure || record_to
        args = ["--no-color"]
        args << "--fail-fast" if stop_at_first_failure
        status = with_fail_fast_off(record_to) do
          ::RSpec::Core::Runner.run([*args, *Array(spec_files)], sink, sink)
        end
        # Reached only when the suite returned: an example that exits the
        # process skips it, and the parent then keeps the row incomplete. A
        # return alone proves nothing: fail-fast turned on mid-run stops RSpec
        # early, so `end` needs a reported outcome for every planned example.
        KillChannel.write_end(record_to) if record_to && KillFormatter.last&.saw_every_example?

        status.zero? ? 0 : failure_code
      ensure
        FileOrder.rank = nil
      end

      # The exit status of a failed run: 2 when no example failed and RSpec
      # recorded an error outside examples, else 1.
      #
      # @api private
      # @return [Integer] 1 or 2.
      def self.failure_code
        world = ::RSpec.world
        outside_examples = world.respond_to?(:non_example_failure) && world.non_example_failure
        outside_examples && ::RSpec.configuration.reporter.failed_examples.empty? ? 2 : 1
      end

      # Runs the top-level example groups in the order of `spec_files` (#203),
      # after RSpec's own ordering, which then decides the order within a file.
      #
      # @api private
      # @param spec_files [String, Array<String>] the files, in run order.
      # @return [void]
      def self.keep_file_order(spec_files)
        FileOrder.rank = Array(spec_files).each_with_index.to_h { |f, i| [File.expand_path(f), i] }
        ::RSpec::Core::World.prepend(FileOrder) unless ::RSpec::Core::World <= FileOrder
      end

      # Prepended on `RSpec::Core::World`: a stable sort of the ordered
      # top-level groups by their file's position. Does nothing without a rank.
      module FileOrder
        class << self
          # Each spec file's position, keyed by absolute path, or nil.
          #
          # @return [Hash{String => Integer}, nil]
          attr_accessor :rank
        end

        # The groups RSpec ordered, sorted by file position.
        #
        # @return [Array<RSpec::Core::ExampleGroup>]
        def ordered_example_groups
          groups = super
          rank = FileOrder.rank
          return groups unless rank

          groups.sort_by.with_index do |group, i|
            file = group.metadata[:absolute_file_path] || File.expand_path(group.file_path)
            [rank.fetch(file, rank.size), i]
          end
        end
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
      # mutant changes a generated description. Example ids need RSpec 3.3 or
      # later; before that no id tells apart examples on one line, so an older
      # RSpec sends no `start` and every row stays incomplete.
      #
      # It writes only from the process that created it, so an example that runs
      # an RSpec suite in a forked process cannot add lines. It writes `start`
      # when the run begins with fail-fast off; a run that could stop early sends
      # no `start`, and its rows stay incomplete. It also registers an
      # `after(:suite)` hook that writes `cleanup` ahead of the suite's own hooks.
      #
      # After the first failure, a run without `--matrix` (`--fail-fast`) skips
      # each later example and each example group that starts later, hooks
      # included, but it still runs the `after(:all)` hooks of the groups it is
      # in. So once an example has failed, the formatter writes `skip` when a
      # later example or group starts and `unskip` when it finishes (see
      # {KillChannel}).
      class KillFormatter
        class << self
          # The formatter of the latest run in this process.
          #
          # @return [KillFormatter, nil]
          attr_accessor :last
        end

        # Registers the formatter with RSpec for the notifications it handles.
        # Called at run time, because rspec-core is not loaded with Mutineer.
        #
        # @return [Class] this class.
        def self.registered
          ::RSpec::Core::Formatters.register(self, :start, :example_started, :example_passed, :example_failed,
                                             :example_pending, :example_group_started, :example_group_finished)
          self
        end

        # @param channel [IO] the write end of the channel.
        def initialize(channel)
          @channel = channel
          @pid = Process.pid
          @failed = false
          @example_skipping = false
          @groups_skipping = []
          @planned = nil
          @reported = 0
          self.class.last = self
        end

        # True when RSpec reported an outcome for every example it planned to run.
        #
        # @return [Boolean]
        def saw_every_example?
          !@planned.nil? && @reported == @planned
        end

        # Sends `start`, unless fail-fast is on or RSpec has no example ids, and
        # registers the hook that sends `cleanup`. RSpec runs `after(:suite)`
        # hooks last-defined first, and this runs once the spec files have
        # loaded, so the hook goes before every hook the suite defines.
        #
        # @param notification [RSpec::Core::Notifications::StartNotification]
        # @return [void]
        def start(notification)
          return unless owner?
          return if ::RSpec.configuration.fail_fast
          return unless ::RSpec::Core::Example.method_defined?(:id)

          @planned = notification.count
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

        # Opens a `skip` region for an example that starts after a failure.
        #
        # @param _notification [RSpec::Core::Notifications::ExampleNotification]
        # @return [void]
        def example_started(_notification)
          return unless owner? && @failed

          @example_skipping = true
          KillChannel.write_skip(@channel)
        end

        # Sends a pass.
        #
        # @param notification [RSpec::Core::Notifications::ExampleNotification]
        # @return [void]
        def example_passed(notification)
          send_event(KillChannel::PASS, notification.example)
          example_finished
        end

        # Sends a kill.
        #
        # @param notification [RSpec::Core::Notifications::FailedExampleNotification]
        # @return [void]
        def example_failed(notification)
          send_event(KillChannel::KILL, notification.example)
          example_finished
          @failed = true
        end

        # A pending or skipped example sends no test line, but it finishes.
        #
        # @param _notification [RSpec::Core::Notifications::ExampleNotification]
        # @return [void]
        def example_pending(_notification)
          example_finished
        end

        # Opens a `skip` region for a group that starts after a failure.
        #
        # @param _notification [RSpec::Core::Notifications::GroupNotification]
        # @return [void]
        def example_group_started(_notification)
          return unless owner?

          # The exception in flight now: RSpec can start and finish a group
          # inside its own `rescue` (a failed `before(:all)` with nested
          # groups), where `$!` is already set.
          @groups_skipping.push([@failed, $!])
          KillChannel.write_skip(@channel) if @failed
        end

        # Closes the group's `skip` region, if it opened one. RSpec sends this
        # after the group's `after(:all)` hooks, from an `ensure`, so it also
        # comes while an exit or a crash unwinds the group. Then `$!` holds an
        # exception that was not in flight when the group started, and the
        # region stays open: the run ended inside it.
        #
        # @param _notification [RSpec::Core::Notifications::GroupNotification]
        # @return [void]
        def example_group_finished(_notification)
          return unless owner?

          opened, in_flight = @groups_skipping.pop
          KillChannel.write_unskip(@channel) if opened && $!.equal?(in_flight)
        end

        private

        # True in the process that created the formatter.
        #
        # @return [Boolean]
        def owner?
          Process.pid == @pid
        end

        # Counts an example's outcome and closes its `skip` region, if any.
        #
        # @return [void]
        def example_finished
          return unless owner?

          @reported += 1
          return unless @example_skipping

          @example_skipping = false
          KillChannel.write_unskip(@channel)
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
        # mutants: its id (RSpec 3.3 and later; see {#start}).
        #
        # @param example [RSpec::Core::Example] the example.
        # @return [String]
        def identify(example)
          example.id
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
