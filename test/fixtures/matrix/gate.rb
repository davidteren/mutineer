# frozen_string_literal: true

# A run that exits the process once its limit check passes, so a mutant of
# `big?` makes one test fail and the next one call exit(0).
class MatrixGate
  LIMIT = 5

  def self.big?(n)
    n > LIMIT
  end

  def self.run(n)
    exit(0) if big?(n)
    n * 2
  end
end
