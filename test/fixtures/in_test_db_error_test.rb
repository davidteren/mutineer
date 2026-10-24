# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

# Stand-ins for the Active Record 7.2 error classes (#296). This file is only
# ever loaded in a forked child, so they never reach the parent suite.
module ActiveRecord
  class StatementInvalid < StandardError; end
  class ConnectionNotEstablished < StandardError
    # Like the real class, which keeps its connection pool: Minitest must
    # rebuild an error it cannot marshal.
    def unmarshalable!
      @pool = Mutex.new
      self
    end
  end
  class ConnectionTimeoutError < ConnectionNotEstablished; end
  class ConnectionNotDefined < ConnectionNotEstablished; end
  class QueryAborted < StatementInvalid; end
  class ConnectionFailed < QueryAborted; end
  class TransactionRollbackError < StatementInvalid; end
  class Deadlocked < TransactionRollbackError; end
  class LockWaitTimeout < StatementInvalid; end
end

# MUTINEER_FIXTURE_FIRST, MUTINEER_FIXTURE_SECOND and MUTINEER_FIXTURE_THIRD
# set each test: pass, exit, crash, timeout,
# (the default), fail, nested_connection (record a database error on an own
# reporter, then pass), or the name of a database error to raise.
# MUTINEER_FIXTURE_SETUP and MUTINEER_FIXTURE_TEARDOWN act on the first test.
class InTestDatabaseErrorFixture < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

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

  def setup
    act(ENV.fetch("MUTINEER_FIXTURE_SETUP", "pass")) if name == "test_a_first"
  end

  def teardown
    act(ENV.fetch("MUTINEER_FIXTURE_TEARDOWN", "pass")) if name == "test_a_first"
  end

  def test_a_first
    act(ENV.fetch("MUTINEER_FIXTURE_FIRST", "pass"))
  end

  def test_b_second
    act(ENV.fetch("MUTINEER_FIXTURE_SECOND", "pass"))
  end

  def test_c_third
    act(ENV.fetch("MUTINEER_FIXTURE_THIRD", "pass"))
  end

  private

  def act(what)
    message = ENV.fetch("MUTINEER_FIXTURE_MESSAGE", "the database is gone")
    case what
    when "pass" then pass
    when "fail" then flunk "an assertion fails"
    when "exit" then exit!(0)
    when "crash" then Process.kill("KILL", Process.pid)
    when "timeout" then sleep 10
    when "connection_unmarshalable" then raise ActiveRecord::ConnectionNotEstablished.new(message).unmarshalable!
    when "nested_connection" then record_on_own_reporter(ActiveRecord::ConnectionNotEstablished.new(message))
    else raise ERRORS.fetch(what), message
    end
  end

  # As a gem that tests its reporters does: the run's verdict must ignore it.
  def record_on_own_reporter(error)
    composite = Minitest::CompositeReporter.new(Minitest::StatisticsReporter.new(StringIO.new))
    composite.start
    failing = Minitest::Result.new("inner")
    failing.failures = [Minitest::UnexpectedError.new(error)]
    composite.record(failing)
    pass
  end
end
