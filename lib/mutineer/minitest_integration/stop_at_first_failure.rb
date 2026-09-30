# frozen_string_literal: true

module Mutineer
  class MinitestIntegration
    # Stops a Minitest run at the first failing test: one failure already
    # kills the mutant. Child-process only, like MinitestIntegration.
    #
    # It sets a flag instead of unwinding the stack, so that class-level
    # wrappers (`after_all`, a block-form transaction) still finish. The
    # remaining tests and classes then return before they start.
    #
    # Minitest 5 and 6 need different hook points. An unknown shape installs
    # no hook, and the run is a full run.
    module StopAtFirstFailure
      # Prepended on `Minitest::CompositeReporter`.
      module RecordFailure
        # Records the result, then sets the stop flag on a failure or an
        # error. Only the outer reporter counts: a test can build and record
        # on its own reporter.
        #
        # @param result [Minitest::Result] the result of one test.
        # @return [void]
        def record(result)
          super
          return if result.passed? || result.skipped?
          return unless equal?(StopAtFirstFailure.armed_reporter)
          return unless StopAtFirstFailure.armed_here?

          StopAtFirstFailure.stopped = true
        end
      end

      # Prepended on the `Minitest` singleton class for Minitest 6.
      module OuterReporter6
        # Keeps the outer reporter. Only the first call counts, because a test
        # can call this method with its own reporter.
        #
        # @param reporter [Minitest::CompositeReporter] the outer reporter.
        # @param options [Hash] the Minitest options.
        # @return [Object] whatever Minitest returns.
        def run_all_suites(reporter, options)
          StopAtFirstFailure.armed_reporter ||= reporter if StopAtFirstFailure.armed_here?
          super
        end
      end

      # Prepended on the `Minitest` singleton class for Minitest 5.
      module OuterReporter5
        # The Minitest 5 form of OuterReporter6#run_all_suites.
        #
        # @param reporter [Minitest::CompositeReporter] the outer reporter.
        # @param options [Hash] the Minitest options.
        # @return [Object] whatever Minitest returns.
        def __run(reporter, options)
          StopAtFirstFailure.armed_reporter ||= reporter if StopAtFirstFailure.armed_here?
          super
        end
      end

      # Prepended on the singleton class of each test class for Minitest 6.
      module SkipAfterStop6
        # Skips the test class after a stop.
        #
        # @param reporter [Minitest::CompositeReporter] the reporter.
        # @param options [Hash] the Minitest options.
        # @return [Object, nil] whatever Minitest returns, or nil when skipped.
        def run_suite(reporter, options = {})
          return if StopAtFirstFailure.stopped_here?

          super
        end

        # Skips one test after a stop, without a record.
        #
        # @param klass [Class] the test class.
        # @param method_name [String] the test method.
        # @param reporter [Minitest::CompositeReporter] the reporter.
        # @return [Object, nil] whatever Minitest returns, or nil when skipped.
        def run(klass, method_name, reporter)
          return if StopAtFirstFailure.stopped_here?

          super
        end
      end

      # Prepended on the singleton class of each test class for Minitest 5.
      module SkipAfterStop5
        # Skips the test class after a stop.
        #
        # @param reporter [Minitest::CompositeReporter] the reporter.
        # @param options [Hash] the Minitest options.
        # @return [Object, nil] whatever Minitest returns, or nil when skipped.
        def run(reporter, options = {})
          return if StopAtFirstFailure.stopped_here?

          super
        end

        # Skips one test after a stop, without a record.
        #
        # @param klass [Class] the test class.
        # @param method_name [String] the test method.
        # @param reporter [Minitest::CompositeReporter] the reporter.
        # @return [Object, nil] whatever Minitest returns, or nil when skipped.
        def run_one_method(klass, method_name, reporter)
          return if StopAtFirstFailure.stopped_here?

          super
        end
      end

      class << self
        # The pid of the armed process. Forked workers inherit the other
        # state, and the pid keeps them from acting on it.
        #
        # @return [Integer, nil]
        attr_accessor :armed_pid

        # The outer reporter of the armed run.
        #
        # @return [Minitest::CompositeReporter, nil]
        attr_accessor :armed_reporter

        # True after the outer reporter records a failure or an error.
        #
        # @return [Boolean, nil]
        attr_accessor :stopped

        # Installs the hooks and arms the stop for this process. Call it after
        # the test files load, so that every test class gets its prepend.
        #
        # @param runnables [Array<Class>] the loaded test classes.
        # @return [Boolean] false when the Minitest shape is unknown.
        def arm!(runnables)
          outer, skip = hooks_for_loaded_minitest
          return false unless outer

          prepend_once(::Minitest::CompositeReporter, RecordFailure)
          prepend_once(::Minitest.singleton_class, outer)
          runnables.each { |klass| prepend_once(klass.singleton_class, skip) }
          self.armed_pid = Process.pid
          self.armed_reporter = nil
          self.stopped = false
          true
        end

        # Clears the armed state.
        #
        # @return [void]
        def disarm!
          self.armed_pid = nil
          self.armed_reporter = nil
          self.stopped = false
        end

        # True when the run is armed in this process.
        #
        # @return [Boolean]
        def armed_here?
          armed_pid == Process.pid
        end

        # True when the armed run in this process has stopped.
        #
        # @return [Boolean]
        def stopped_here?
          stopped == true && armed_here?
        end

        private

        # Picks the hook modules for the loaded Minitest.
        #
        # @return [Array(Module, Module), nil] the outer reporter hook and the
        #   skip hook, or nil for an unknown shape.
        def hooks_for_loaded_minitest
          runnable = ::Minitest::Runnable
          if ::Minitest.respond_to?(:run_all_suites) && runnable.respond_to?(:run_suite)
            [OuterReporter6, SkipAfterStop6]
          elsif ::Minitest.respond_to?(:__run) && runnable.respond_to?(:run_one_method)
            [OuterReporter5, SkipAfterStop5]
          end
        end

        # Prepends `mod` on `target` once. A copy on a superclass does not
        # count, because it comes after the own methods of `target`.
        #
        # @param target [Module] the class or singleton class.
        # @param mod [Module] the module to prepend.
        # @return [void]
        def prepend_once(target, mod)
          return if target.ancestors.take_while { |a| !a.equal?(target) }.include?(mod)

          target.prepend(mod)
        end
      end
    end
  end
end
