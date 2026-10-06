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

  # Known limit: a one-line or endless def called at load. Its body is on the
  # def line, which Ruby counts when the method is defined, so line coverage
  # cannot tell that it ran: a false survivor under redefine.
  def self.bump(x); x + 2; end

  def self.short(x) = x * 3

  DOUBLED = double(1)
  BUMPED = bump(1)
  SHORT = short(1)
end
