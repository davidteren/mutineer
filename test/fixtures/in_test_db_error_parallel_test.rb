# frozen_string_literal: true

require "minitest/autorun"

# Stand-ins for the Active Record 7.2 error classes (#296, #347). This file is
# only ever loaded in a forked child, so they never reach the parent suite.
module ActiveRecord
  class StatementInvalid < StandardError; end
  class ConnectionNotEstablished < StandardError; end
  class ConnectionTimeoutError < ConnectionNotEstablished; end
  class ConnectionNotDefined < ConnectionNotEstablished; end
  class QueryAborted < StatementInvalid; end
  class ConnectionFailed < QueryAborted; end
  class TransactionRollbackError < StatementInvalid; end
  class Deadlocked < TransactionRollbackError; end
  class LockWaitTimeout < StatementInvalid; end
end

# Two workers, even on a one-CPU machine: `parallelize_me!` does nothing
# without an executor, and one worker would run these tests serially and
# deadlock on the barrier below.
require "minitest/parallel"
Minitest.parallel_executor = Minitest::Parallel::Executor.new(2)

# MUTINEER_FIXTURE_SERIAL sets the serial test, which Minitest runs before the
# parallel class. pass (the default) or the same actions as the parallel tests.
module InTestDatabaseErrorParallelActions
  ERRORS = {
    "connection" => ActiveRecord::ConnectionNotEstablished,
    "pool_timeout" => ActiveRecord::ConnectionTimeoutError,
    "connection_not_defined" => ActiveRecord::ConnectionNotDefined,
    "connection_failed" => ActiveRecord::ConnectionFailed,
    "deadlock" => ActiveRecord::Deadlocked,
    "lock_wait" => ActiveRecord::LockWaitTimeout,
    "statement_invalid" => ActiveRecord::StatementInvalid,
    "runtime" => RuntimeError
  }.freeze

  # Runs one fixture action. `fail` is an assertion. A database name raises
  # that stand-in.
  #
  # @param what [String]
  # @return [void]
  def act(what)
    message = ENV.fetch("MUTINEER_FIXTURE_MESSAGE", "the database is gone")
    case what
    when "pass" then pass
    when "fail" then flunk "an assertion fails"
    else raise ERRORS.fetch(what), message
    end
  end
end

class InTestDatabaseErrorParallelSerial < Minitest::Test
  include InTestDatabaseErrorParallelActions

  def test_serial
    act(ENV.fetch("MUTINEER_FIXTURE_SERIAL", "pass"))
  end
end

# Queue order is test_a_first, then test_b_second (`runnable_methods` below),
# while `parallelize_me!` keeps `test_order` / `run_order` at `:parallel`.
# The barrier makes test_b finish, and be recorded, before test_a finishes.
# A verdict that follows finish order therefore picks test_b. The run's
# verdict has to pick test_a (#347).
class InTestDatabaseErrorParallel < Minitest::Test
  include InTestDatabaseErrorParallelActions
  parallelize_me!

  # The order the main thread enqueues, independent of the seed's shuffle.
  #
  # @return [Array<String>]
  def self.runnable_methods
    %w[test_a_first test_b_second]
  end

  # test_a has started and is waiting. test_b pops this before it fails.
  STARTED = Queue.new

  # test_b has finished its body. test_a pops this before it fails.
  RELEASE = Queue.new

  def test_a_first
    STARTED << :a
    RELEASE.pop
    act(ENV.fetch("MUTINEER_FIXTURE_FIRST", "pass"))
  end

  def test_b_second
    STARTED.pop
    begin
      act(ENV.fetch("MUTINEER_FIXTURE_SECOND", "pass"))
    ensure
      RELEASE << :b
    end
  end
end
