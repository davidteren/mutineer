# frozen_string_literal: true

# PORO for the RSpec kill-matrix identity fixtures.
class MatrixCalc
  def add(a, b)
    a + b
  end

  def mul(a, b)
    a * b
  end

  def pos?(n)
    n > 0
  end
end
