# frozen_string_literal: true

# #503: the file assigns the constant that the class statement inherits from.
# The daemon loads this file again for each mutant, which raised "superclass
# mismatch" before reload kept the constant's class.
LedgerRowBase = Struct.new(:cents)

class LedgerRow < LedgerRowBase
  def zero? = cents == 0

  # #512: the superclass sets a local that a later line reads.
  class Line < (line_base = Struct.new(:count))
    def single? = count == 1
  end
  LINE_BASE = line_base
end
