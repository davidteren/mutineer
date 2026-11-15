# frozen_string_literal: true

# Stand-ins for the Active Record 7.2 error classes (#347). Loaded only in a
# forked child, so they never reach the parent suite.
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

# MUTINEER_FIXTURE_FIRST and MUTINEER_FIXTURE_SECOND set each example: pass
# (the default), fail, or a database-error name. MUTINEER_FIXTURE_BEFORE runs
# in `before`, MUTINEER_FIXTURE_AFTER in `after`, for the first example only.
RSpec.describe "in-example database error", order: :defined do
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

  def act(what)
    return if what.nil? || what == "pass"

    message = ENV.fetch("MUTINEER_FIXTURE_MESSAGE", "the database is gone")
    if what == "fail"
      expect(1).to eq(2)
    else
      raise ERRORS.fetch(what), message
    end
  end

  def first_example?
    RSpec.current_example.description == "runs first"
  end

  before { act(ENV["MUTINEER_FIXTURE_BEFORE"]) if ENV["MUTINEER_FIXTURE_BEFORE"] && first_example? }

  after { act(ENV["MUTINEER_FIXTURE_AFTER"]) if ENV["MUTINEER_FIXTURE_AFTER"] && first_example? }

  it "runs first" do
    act(ENV.fetch("MUTINEER_FIXTURE_FIRST", "pass"))
  end

  it "runs second" do
    act(ENV.fetch("MUTINEER_FIXTURE_SECOND", "pass"))
  end
end
