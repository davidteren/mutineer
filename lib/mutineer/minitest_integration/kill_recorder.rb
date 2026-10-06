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

      # Prepended on each loaded test class: one test's run. Serial and parallel
      # runs both call it, in Minitest 5 and 6.
      module MarkSkippedTest
        # Runs the test inside a `skip` region once a serial test has killed.
        #
        # @return [Minitest::Result]
        def run
          KillRecorder.skipping { super }
        end
      end

      # Prepended on each loaded test class's singleton under Minitest 6: one
      # class's run, user wrappers included.
      module MarkSkippedClass6
        # Runs the class inside a `skip` region once a serial test has killed.
        #
        # @param reporter [Minitest::CompositeReporter]
        # @param options [Hash]
        # @return [Object]
        def run_suite(reporter, options = {})
          KillRecorder.class_starting(self)
          KillRecorder.skipping { super }
        end
      end

      # The Minitest 5 form of {MarkSkippedClass6}.
      module MarkSkippedClass5
        # Runs the class inside a `skip` region once a serial test has killed.
        #
        # @param reporter [Minitest::CompositeReporter]
        # @param options [Hash]
        # @return [Object]
        def run(reporter, options = {})
          KillRecorder.class_starting(self)
          KillRecorder.skipping { super }
        end
      end

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

        # True once a serial test killed: from then on, a run without `--matrix`
        # skips each later test and class.
        #
        # @return [Boolean, nil]
        attr_accessor :serial_killed

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
          class_hook = outer.equal?(OuterReporter::Hook6) ? MarkSkippedClass6 : MarkSkippedClass5
          runnables.each do |klass|
            OuterReporter.prepend_once(klass, MarkSkippedTest)
            OuterReporter.prepend_once(klass.singleton_class, class_hook)
          end
          OuterReporter.register(self)
          self.armed_pid = Process.pid
          self.armed_reporter = nil
          self.channel = channel
          self.parallel_marked = false
          self.runnables = runnables
          self.seen = 0
          self.serial_killed = false
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
          self.runnables = nil
          self.serial_killed = false
        end

        # Writes the `parallel` line when the first parallel class starts. The
        # class object is known here, so an anonymous class (which Minitest
        # records with no name) counts too. Minitest runs every serial class
        # first, so a kill before this line came from a serial test.
        #
        # @param klass [Class] the test class starting its run.
        # @return [void]
        def class_starting(klass)
          return unless channel && armed_here? && parallel?(klass)

          LOCK.synchronize { mark_parallel }
        end

        # Runs the block between `skip` and `unskip` when a serial test has
        # killed in this armed process, else just runs it. No `ensure`: a block
        # that never returns (an exit, a crash) must leave its region open, so
        # the parent knows the child ended where a run without `--matrix`
        # would not have been.
        #
        # @yieldreturn [Object]
        # @return [Object] the block's value.
        def skipping
          open = channel && serial_killed && armed_here?
          KillChannel.write_skip(channel) if open
          value = yield
          KillChannel.write_unskip(channel) if open
          value
        end

        # Sends one result recorded on `reporter`: a pass, or a kill for a
        # failure or an error. Skips send no test line, though they count as
        # seen, and results on other reporters count for nothing. The
        # `parallel` line goes out when the first parallel class starts (see
        # {.class_starting}), so a kill that precedes it came from a serial test.
        #
        # @param reporter [Minitest::CompositeReporter] the recording reporter.
        # @param result [Minitest::Result] the result of one test.
        # @return [void]
        def record(reporter, result)
          return unless channel && outer_reporter?(reporter)

          LOCK.synchronize do
            self.seen += 1
            next if result.skipped?

            event = result.passed? ? KillChannel::PASS : KillChannel::KILL
            self.serial_killed = true if event == KillChannel::KILL && !parallel_marked
            file, line = Array(result.source_location)
            KillChannel.write(channel, event, file, *name_and_id(result, line))
          end
        end

        private

        # The test's name and id. `Class#method` is unique within a run, so the
        # name is also the id. An anonymous class has no name (Minitest records
        # nil), so its tests would all merge into `#method`; their id adds the
        # line that defines the method, which no mutant changes. The test's file
        # is already part of its identity, so the id holds no path.
        #
        # @param result [Minitest::Result] the result of one test.
        # @param line [Integer, nil] the line that defines the test method.
        # @return [Array(String, String)] name and id.
        def name_and_id(result, line)
          return ["#{result.klass}##{result.name}"] * 2 unless result.klass.to_s.empty?

          name = "(anonymous)##{result.name}"
          [name, "#{name}@#{line}"]
        end

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
