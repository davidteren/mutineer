# frozen_string_literal: true

module Mutineer
  class MinitestIntegration
    # Finds the outer reporter of a Minitest run, for the hooks that act only on
    # the run's own results. A test can build a reporter of its own and record
    # on it, or start a nested run, so the first reporter the run hands to its
    # suites is the one that counts. Child-process only, like
    # MinitestIntegration.
    #
    # A client module extends {Client}, registers here, and sets its armed pid.
    # The hook then gives the outer reporter to each client armed in this
    # process. Minitest 5 and 6 need different hook points; an unknown shape
    # gets no hook.
    module OuterReporter
      # Prepended on the `Minitest` singleton class for Minitest 6.
      module Hook6
        # Hands the outer reporter to the armed clients. Only the first call
        # counts, because a test can call this method with its own reporter.
        #
        # @param reporter [Minitest::CompositeReporter] the outer reporter.
        # @param options [Hash] the Minitest options.
        # @return [Object] whatever Minitest returns.
        def run_all_suites(reporter, options)
          OuterReporter.seen(reporter)
          super
        end
      end

      # Prepended on the `Minitest` singleton class for Minitest 5.
      module Hook5
        # The Minitest 5 form of Hook6#run_all_suites.
        #
        # @param reporter [Minitest::CompositeReporter] the outer reporter.
        # @param options [Hash] the Minitest options.
        # @return [Object] whatever Minitest returns.
        def __run(reporter, options)
          OuterReporter.seen(reporter)
          super
        end
      end

      # The per-process state a client keeps. Forked workers inherit it, and
      # the pid keeps them from acting on it.
      module Client
        # The pid of the armed process.
        #
        # @return [Integer, nil]
        attr_accessor :armed_pid

        # The outer reporter of the armed run.
        #
        # @return [Minitest::CompositeReporter, nil]
        attr_accessor :armed_reporter

        # True when the client is armed in this process.
        #
        # @return [Boolean]
        def armed_here?
          armed_pid == Process.pid
        end

        # True when `reporter` is the outer reporter of the run armed in this
        # process.
        #
        # @param reporter [Minitest::CompositeReporter] the recording reporter.
        # @return [Boolean]
        def outer_reporter?(reporter)
          armed_here? && reporter.equal?(armed_reporter)
        end
      end

      class << self
        # The registered clients, in registration order.
        #
        # @return [Array<Module>]
        def clients
          @clients ||= []
        end

        # Registers a client once.
        #
        # @param client [Module] a module that extends {Client}.
        # @return [void]
        def register(client)
          clients << client unless clients.include?(client)
        end

        # Gives `reporter` to every client armed in this process that has no
        # outer reporter yet.
        #
        # @param reporter [Minitest::CompositeReporter] a reporter a run uses.
        # @return [void]
        def seen(reporter)
          clients.each do |client|
            client.armed_reporter ||= reporter if client.armed_here?
          end
        end

        # The outer-reporter hook for the loaded Minitest.
        #
        # @return [Module, nil] {Hook6}, {Hook5}, or nil for an unknown shape.
        def hook_for_loaded_minitest
          runnable = ::Minitest::Runnable
          if ::Minitest.respond_to?(:run_all_suites) && runnable.respond_to?(:run_suite)
            Hook6
          elsif ::Minitest.respond_to?(:__run) && runnable.respond_to?(:run_one_method)
            Hook5
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
