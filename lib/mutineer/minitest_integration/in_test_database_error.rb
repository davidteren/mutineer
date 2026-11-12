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
    # full run and a `--matrix` run give the same verdict. "First" follows
    # Minitest's run order. Serial classes finish before `parallelize_me!`
    # classes. Inside a parallel class the order is the queue order, the same
    # order `runnable_methods` produced, not the order the worker threads
    # finish (#347). A mutant that makes one parallel test hit a database
    # error and another fail an assertion therefore scores the same way on
    # every run.
    # Stdlib only: the app-side daemon loads this file without Prism. An
    # unknown Minitest shape arms nothing, and the run keeps its 0 or 1.
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

      # Subclasses of {NAMES} that point at the code, not the database. Rails 8
      # raises `ConnectionNotDefined` for a role or shard that no connection
      # defines, which a mutant of a `connected_to` call can cause. Rails 7.2
      # raises a plain `ConnectionNotEstablished` there, so on 7.2 such a mutant
      # scores `error`. The message is not matched (plan Q2).
      CODE_ERROR_NAMES = %w[ActiveRecord::ConnectionNotDefined].freeze

      # The lock errors in {NAMES}, which get their own stderr hint.
      LOCK_ERROR_NAMES = %w[ActiveRecord::Deadlocked ActiveRecord::LockWaitTimeout].freeze

      # Guards the parallel-queue index. The main thread writes it as it
      # enqueues, and a worker thread reads it when that test is recorded.
      QUEUE_LOCK = Mutex.new

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

      # Prepended on `Minitest::Parallel::Executor`. Records each job as the
      # main thread enqueues it, which is Minitest's run order for a
      # `parallelize_me!` class. The workers then finish in another order.
      module NoteQueueOrder
        # Records the job, then queues it.
        #
        # @param work [Array, Object] `[klass, method_name, reporter]`, or
        #   whatever else the executor was given.
        # @return [Object] whatever `Minitest::Parallel::Executor#<<` returns.
        def <<(work)
          InTestDatabaseError.note_queued(work)
          super
        end
      end

      class << self
        # The first failed serial result's database error, false when that
        # result failed for another reason, or nil before any serial failure.
        # Parallel results are kept separately, in queue order.
        #
        # @return [Exception, false, nil]
        attr_accessor :first_failure

        # Parallel failures as `[queue index, exception or false]`, in the
        # order they were recorded. The earliest index decides when no serial
        # test failed.
        #
        # @return [Array<Array>]
        attr_accessor :parallel_failures

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
          reset_failures!
          hook_queue_order
          true
        end

        # Clears the armed state.
        #
        # @return [void]
        def disarm!
          self.armed_pid = nil
          self.armed_reporter = nil
          reset_failures!
        end

        # Keeps the failures recorded on the outer reporter. A serial failure
        # is kept only when it is the first one. A `parallelize_me!` failure
        # is kept with its queue index, so the earliest queued test decides
        # even when another thread finishes first (#347). Minitest records
        # from several threads only under its own reporter lock. A result it
        # cannot read counts as an ordinary failure, so a fault here keeps the
        # old verdict and never turns a kill into an error.
        #
        # @param reporter [Minitest::CompositeReporter] the recording reporter.
        # @param result [Minitest::Result] the result of one test.
        # @return [void]
        def record(reporter, result)
          return if result.passed? || result.skipped?
          return unless outer_reporter?(reporter)

          outcome = database_error(result.failures.first) || false
          # Zero is the first queued test. A missing index is a serial test,
          # or a parallel test the queue hook did not see.
          index = queue_index(result)
          if index.nil?
            self.first_failure = outcome if first_failure.nil?
          else
            parallel_failures << [index, outcome]
          end
        rescue StandardError
          self.first_failure = false if first_failure.nil?
        end

        # The run's exit code: 2 instead of 1 when the armed run's first failure
        # was a database error. Then it also writes one line on stderr that
        # names the error. `STDERR`, not `warn`: a test can leave `$stderr` as
        # a `StringIO`. The flush matters because both fork boundaries end with
        # `exit!`.
        #
        # @param code [Integer] 0 or 1 from the run.
        # @return [Integer] `code`, or 2.
        def exit_code(code)
          error = deciding_error if armed_here?
          return code unless code == 1 && error

          STDERR.puts(line(error))
          STDERR.flush
          2
        end

        # The database error a failure wraps. The first entry of a result is
        # the error that ended the test: Minitest records the setup or body
        # error before a teardown error. The cause chain is not read: Active
        # Record already translates driver errors into the listed classes.
        #
        # Minitest before 5.14 names the wrapped error `exception`.
        #
        # Shared with the matrix recorder so an unavailable database outcome
        # cannot be named as a mutation kill.
        #
        # @api private
        # @param failure [Minitest::Assertion, nil] the result's first entry.
        # @return [Exception, nil]
        def database_error(failure)
          return unless failure.is_a?(::Minitest::UnexpectedError)

          error = failure.respond_to?(:error) ? failure.error : failure.exception
          error if database_exception?(error)
        end

        # True when `error` is one of {NAMES} and not one of {CODE_ERROR_NAMES}.
        # Shared with the RSpec runner, which has no `Minitest::UnexpectedError`
        # wrapper (#347).
        #
        # @param error [Exception, nil]
        # @return [Boolean]
        def database_exception?(error)
          return false if error.nil?
          return false if loaded(CODE_ERROR_NAMES).any? { |klass| error.is_a?(klass) }

          loaded(NAMES).any? { |klass| error.is_a?(klass) }
        end

        # Writes the stderr line for `error` and flushes it. The same line
        # {exit_code} writes. `STDERR`, not `warn`: a test can leave `$stderr`
        # as a `StringIO`. Shared with the RSpec runner (#347).
        #
        # @param error [Exception] the database error.
        # @return [void]
        def warn_database_error(error)
          STDERR.puts(line(error))
          STDERR.flush
        end

        # Remembers where a parallel job sits in the outer run's queue. Called
        # on the main thread, before a worker can run the job. A job for
        # another reporter is a test running a parallel class itself; its
        # order is not the run's, so it is ignored (review of #453). Never
        # raises: a fault leaves that test without an index, and {record} then
        # treats it as serial.
        #
        # @param work [Object] the value passed to `Minitest::Parallel::Executor#<<`.
        # @return [void]
        def note_queued(work)
          return unless work.is_a?(Array)

          klass, method_name, reporter = work
          return unless klass.is_a?(Module) && method_name
          return if other_reporter?(reporter)

          location = klass.instance_method(method_name).source_location
          key = queue_key(klass.name, method_name, location)
          QUEUE_LOCK.synchronize do
            positions = queue_positions
            positions[key] ||= positions.size
          end
        rescue StandardError
          nil
        end

        private

        # The database error that decides the run, false when the first failure
        # was ordinary, or nil when nothing failed. A serial failure wins: those
        # classes run before any parallel class. Otherwise the parallel failure
        # with the smallest queue index wins.
        #
        # @return [Exception, false, nil]
        def deciding_error
          return first_failure unless first_failure.nil?

          earliest = parallel_failures.min_by { |index, _outcome| index }
          earliest&.last
        end

        # Clears the failures and the queue index for a new run.
        #
        # @return [void]
        def reset_failures!
          self.first_failure = nil
          self.parallel_failures = []
          QUEUE_LOCK.synchronize { @queue_positions = {} }
        end

        # Installs {NoteQueueOrder} when this Minitest has a parallel executor.
        # An older shape without one keeps the record-order rule.
        #
        # @return [void]
        def hook_queue_order
          OuterReporter.prepend_once(::Minitest::Parallel::Executor, NoteQueueOrder)
        rescue NameError
          nil
        end

        # True when `reporter` belongs to a nested run, not the outer one.
        # False when the outer reporter is not known yet, so the jobs that
        # build the run's queue are still recorded.
        #
        # @param reporter [Minitest::CompositeReporter, nil]
        # @return [Boolean]
        def other_reporter?(reporter)
          mine = armed_reporter
          !!(mine && reporter && !reporter.equal?(mine))
        end

        # The queue index of `result`, or nil when it was not queued.
        #
        # @param result [Minitest::Result]
        # @return [Integer, nil]
        def queue_index(result)
          location = result.source_location if result.respond_to?(:source_location)
          key = queue_key(result.klass, result.name, location)
          QUEUE_LOCK.synchronize { queue_positions[key] }
        rescue StandardError
          nil
        end

        # The key {note_queued} and {queue_index} share. The class name is
        # empty for an anonymous class; the source location tells those apart.
        #
        # @param klass_name [String, nil]
        # @param method_name [String, Symbol]
        # @param location [Array, nil] `[file, line]` from `source_location`.
        # @return [Array] class name, method name, and source location.
        def queue_key(klass_name, method_name, location)
          [klass_name.to_s, method_name.to_s, location]
        end

        # The positions recorded by {note_queued}, keyed by {queue_key}.
        #
        # @return [Hash{Array => Integer}]
        def queue_positions
          @queue_positions ||= {}
        end

        # The named classes this process has loaded.
        #
        # @param names [Array<String>] constant names.
        # @return [Array<Class>]
        def loaded(names)
          names.filter_map { |name| Object.const_get(name) if Object.const_defined?(name) }
        end

        # The stderr line. Redacted before the cut to one line, so a cut can
        # never split a password away from its URL. The wording fits every run,
        # the clean check included, and a mutant can cause the error too.
        #
        # @param error [Exception] the database error.
        # @return [String]
        def line(error)
          text = Redaction.text("#{error.class}: #{error.message}".scrub)
          text = text.lines.first.to_s.chomp.delete_suffix(".")
          "[mutineer-child] a test failed with a database error, so the run has no verdict: #{text}. #{hint(error)}"
        end

        # What to check for the error: a lock error comes from a second
        # connection or thread, any other from the server.
        #
        # @param error [Exception] the database error.
        # @return [String]
        def hint(error)
          if loaded(LOCK_ERROR_NAMES).any? { |klass| error.is_a?(klass) }
            "Look for a test or app code that holds a lock on a second connection or thread."
          else
            "Check that the database server is up and has free connections."
          end
        end
      end
    end
  end
end
