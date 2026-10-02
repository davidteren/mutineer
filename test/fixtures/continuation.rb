# frozen_string_literal: true

# Ruby counts the first line of a statement only. It counts no line for the
# second entry of a hash, or for the body of a heredoc.
class Continuation
  def self.summary(counts)
    {
      yes: counts.fetch(true, 0),
      no: counts.fetch(false, 0)
    }
  end

  def self.message(count)
    String.new(<<~TEXT)
      #{count > 0}
    TEXT
  end
end
