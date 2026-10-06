# frozen_string_literal: true

# count_to loops forever when next_i stops moving forward.
class MatrixLooper
  def self.next_i(i)
    i + 1
  end

  def self.count_to(n)
    i = 0
    i = next_i(i) while i < n
    i
  end
end
