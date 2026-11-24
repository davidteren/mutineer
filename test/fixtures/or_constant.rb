# frozen_string_literal: true

# #529: a second load skips each of these definitions, because the first load
# set the constant. Reload cannot place a method inside them.
OrCell ||= Struct.new(:x) do
  def one? = x == 1
end

GuardedCell = Struct.new(:x) do
  def two? = x == 2
end unless defined?(GuardedCell)

unless defined?(BlockedCell)
  BlockedCell = Struct.new(:x) do
    def three? = x == 3
  end
end

unless defined?(StatedCell)
  class StatedCell
    def four?(x) = x == 4
  end
end

if !defined?(NegatedCell)
  class NegatedCell
    def five?(x) = x == 5
  end
end

# The body does not define the tested name, so it runs again on each load.
unless defined?(NeverDefinedGuard)
  class ShimmedCell
    def six?(x) = x == 6
  end
end
