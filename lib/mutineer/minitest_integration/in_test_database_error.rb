# frozen_string_literal: true

require_relative "outer_reporter"
require_relative "../redaction"

module Mutineer
  class MinitestIntegration
    # Scores a run as `error`, not `killed`, when its first failing test failed
    # because of an Active Record connection or lock error (#296). Such a
    # failure says the database broke, not that a test caught the mutant.
    # Child-process only, like MinitestIntegration.
    #
    # Only the first failed result on the outer reporter counts (see
    # {OuterReporter}). A run that stops at its first failure ends there, so a
    # full run and a `--matrix` run give the same verdict. Stdlib only: the
    # app-side daemon loads this file without Prism. An unknown Minitest shape
    # arms nothing, and the run keeps its 0 or 1.
    module InTestDatabaseError
      extend OuterReporter::Client

      # The Active Record errors that mean the database, not the test, failed.
      # Subclasses count too: `ConnectionTimeoutError` (a pool timeout) and
      # `DatabaseConnectionError` are `ConnectionNotEstablished`. Looked up by
      # name when a result is recorded, so a project without Active Record, or
      # a Rails without `ConnectionFailed` (before 7.1), matches nothing. Other
      # `StatementInvalid` errors are not here: a mutant can cause bad SQL.
      NAMES = %w[
        ActiveRecord::ConnectionNotEstablished
        ActiveRecord::ConnectionFailed
        ActiveRecord::Deadlocked
        ActiveRecord::LockWaitTimeout
      ].freeze

      # Prepended on `Minitest::CompositeReporter`.
      module RecordFirstFailure
        # Records the result, then lets the module keep the first failure.
        #
        # @param result [Minitest::Result] the result of one test.
        # @return [void]
        def record(result)
          super
          InTestDatabaseError.record(self, result)
        end
      end

      class << self
        # The first failed result's database error, false when that result
        # failed for another reason, or nil before any failure.
        #
        # @return [Exception, false, nil]
        attr_accessor :first_failure

        # Installs the hooks and arms the module for this process.
        #
        # @return [Boolean] false when the Minitest shape is unknown.
        def arm!
          outer = OuterReporter.hook_for_loaded_minitest
          return false unless outer

          OuterReporter.prepend_once(::Minitest::CompositeReporter, RecordFirstFailure)
          OuterReporter.prepend_once(::Minitest.singleton_class, outer)
          OuterReporter.register(self)
          self.armed_pid = Process.pid
          self.armed_reporter = nil
          self.first_failure = nil
          true
        end

        # Clears the armed state.
        #
        # @return [void]
        def disarm!
          self.armed_pid = nil
          self.armed_reporter = nil
          self.first_failure = nil
        end

        # Keeps the first failed result recorded on the outer reporter. Minitest
        # records from several threads only under its own reporter lock.
        #
        # @param reporter [Minitest::CompositeReporter] the recording reporter.
        # @param result [Minitest::Result] the result of one test.
        # @return [void]
        def record(reporter, result)
          return if result.passed? || result.skipped?
          return unless first_failure.nil? && outer_reporter?(reporter)

          self.first_failure = database_error(result.failures.first) || false
        end

        # The run's exit code: 2 instead of 1 when the armed run's first failure
        # was a database error, with one line on stderr that names it.
        # `STDERR`, not `warn`: a test can leave `$stderr` as a `StringIO`. The
        # flush matters because both fork boundaries end with `exit!`.
        #
        # @param code [Integer] 0 or 1 from the run.
        # @return [Integer] `code`, or 2.
        def exit_code(code)
          error = first_failure if armed_here?
          return code unless code == 1 && error

          STDERR.puts(line(error))
          STDERR.flush
          2
        end

        private

        # The database error a failure wraps. The first entry of a result is
        # the error that ended the test: Minitest records the setup or body
        # error before a teardown error. The cause chain is not read: Active
        # Record already translates driver errors into the listed classes.
        #
        # @param failure [Minitest::Assertion, nil] the result's first entry.
        # @return [Exception, nil]
        def database_error(failure)
          return unless failure.is_a?(::Minitest::UnexpectedError)

          error = failure.error
          error if database_classes.any? { |klass| error.is_a?(klass) }
        end

        # The listed classes this process has loaded.
        #
        # @return [Array<Class>]
        def database_classes
          NAMES.filter_map { |name| Object.const_get(name) if Object.const_defined?(name) }
        end

        # The stderr line. Redacted before the cut to one line, so a cut can
        # never split a password away from its URL.
        #
        # @param error [Exception] the database error.
        # @return [String]
        def line(error)
          text = Redaction.text("#{error.class}: #{error.message}").lines.first.to_s.chomp.delete_suffix(".")
          "[mutineer-child] in-test database error, not a test failure: #{text}. " \
            "Check the database server and its connection limit."
        end
      end
    end
  end
end
