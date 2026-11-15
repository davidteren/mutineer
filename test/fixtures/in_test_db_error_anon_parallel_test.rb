# frozen_string_literal: true

require "minitest/autorun"
require "minitest/parallel"

# Stand-in for the connection error (#347). Loaded only in a forked child.
module ActiveRecord
  class ConnectionNotEstablished < StandardError; end
end

# Two workers, so the connection test can finish before the assertion test.
Minitest.parallel_executor = Minitest::Parallel::Executor.new(2)

# Both anonymous classes inherit this one method, so a queue key of class
# name plus source location is the same for both. The assertion class is
# queued first and waits until the connection class has been recorded.
module InTestDatabaseErrorAnonShared
  GATE = Queue.new

  def test_shared
    if self.class.failure_mode == :fail
      GATE.pop
      flunk "an assertion fails"
    else
      begin
        raise ActiveRecord::ConnectionNotEstablished, "the database is gone"
      ensure
        GATE << :done
      end
    end
  end
end

# Lets the suite enqueue the assertion class before the connection class.
# Both stay anonymous: they are not assigned to constants.
ANON_ORDER = [
  Class.new(Minitest::Test) do
    include InTestDatabaseErrorAnonShared
    parallelize_me!
    def self.failure_mode = :fail
  end,
  Class.new(Minitest::Test) do
    include InTestDatabaseErrorAnonShared
    parallelize_me!
    def self.failure_mode = :connection
  end
].freeze

class InTestDatabaseErrorAnonSerial < Minitest::Test
  def test_placeholder
    pass
  end
end

Minitest::Runnable.runnables.define_singleton_method(:shuffle) do
  [InTestDatabaseErrorAnonSerial, *ANON_ORDER]
end
