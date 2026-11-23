# frozen_string_literal: true

# #503: the file assigns the constant a class statement inherits from. Each
# `Struct.new` and `Data.define` builds a new class, so a second load must keep
# the live constant.
BaseRow = Struct.new(:v) do
  def in_block? = v == 1
end

class Row < BaseRow
  def three? = v == 3

  def weak? = v == 4
end

module Ledger
  Entry = Data.define(:cents)

  class Credit < Entry
    def zero? = cents == 0
  end
end
