# frozen_string_literal: true

# #187: mutants that must keep their verdict even though the class body calls
# methods while it loads.
class Shelf
  # Runs at load and at test time, and the test checks it: stays killed.
  def self.double(x)
    x * 2
  end

  # Runs only at test time, weakly tested: stays survived.
  def self.tax(x)
    x + 1
  end

  # #209: a one-line and an endless def called at load. Their body is on the
  # def line, which Ruby counts when the method is defined, so only the
  # method's call count tells that they ran: ran_at_load.
  def self.bump(x); x + 2; end

  def self.short(x) = x * 3

  # #209: one-line defs that only the tests call keep their verdict.
  def self.half(x) = x / 2

  def self.ping(x); x - 1; end

  DOUBLED = double(1)
  BUMPED = bump(1)
  SHORT = short(1)
end
