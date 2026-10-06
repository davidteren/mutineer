# frozen_string_literal: true

# An account whose tests mix setup errors, skips, errors, a blind test,
# tests shared through a module, and a parallel class.
class MatrixAcct
  def initialize(balance)
    @balance = balance
  end

  def deposit(x)
    @balance + x
  end

  def withdraw(x)
    raise ArgumentError, "overdraw" if x > @balance

    @balance - x
  end

  def ok?
    @balance >= 0 && true
  end

  def fee(x)
    x * 2
  end
end
