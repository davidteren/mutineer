# frozen_string_literal: true

require "minitest/autorun"
require_relative "acct"
require_relative "support/shared_tests"

class MatrixAcctSetupTest < Minitest::Test
  def setup
    @acct = MatrixAcct.new(10)
    @left = @acct.withdraw(3) # raises in setup under some mutants
  end

  def test_left
    assert_equal 7, @left
  end

  def test_skipped
    skip "not yet"
  end

  def test_errors_on_mutant
    # A NoMethodError (an error, not a failure) when fee returns a Float.
    assert_equal 4, MatrixAcct.new(1).fee(2).digits.sum
  end

  def test_blind
    MatrixAcct.new(10).ok?
  end
end

class MatrixAcctA < Minitest::Test
  include MatrixSharedAcctTests
end

class MatrixAcctB < Minitest::Test
  include MatrixSharedAcctTests

  def test_ok
    assert MatrixAcct.new(0).ok?
  end
end

class MatrixAcctParallel < Minitest::Test
  parallelize_me!

  10.times do |i|
    define_method("test_p#{i}") { assert_equal 10 + i, MatrixAcct.new(10).deposit(i) }
  end
end
