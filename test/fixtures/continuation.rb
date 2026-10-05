# frozen_string_literal: true

# Ruby counts one line of a statement only. It counts no line for the second
# entry of a hash, and for an assigned heredoc it counts the body line.
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

  def self.note(count)
    text = <<~TEXT
      #{count.zero?}
    TEXT
    text
  end

  def self.label(flag)
    text = "#{if flag
      :never_reached
    end}"
    text
  end

  def self.empty =
    :never_counted

  def self.untested; [:a,
    :never_called]; end
end
