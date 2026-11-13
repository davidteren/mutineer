# frozen_string_literal: true

# Later lines of one statement. Ruby counts one line of each. The tests in
# continuation_reach_test.rb run every later line. The tests in
# continuation_reach_miss_test.rb run only the line Ruby counts.
class ContinuationReach
  def self.adult?(age, verified)
    verified &&
      age > 17
  end

  def self.labels(users)
    users.map { |u| u.
      name.
      length > 1 }
  end

  def self.widths(users)
    users.map { |u| format("%s",
      u.length > 1) }
  end

  def self.tally(flag, n)
    flag && {
      n: n,
      wide: n > 1
    }
  end

  def self.note(flag, n)
    flag && <<~TEXT
      #{n > 1}
    TEXT
  end

  def self.sums(flag, a, b)
    flag &&
      a +
        b
  end
end
