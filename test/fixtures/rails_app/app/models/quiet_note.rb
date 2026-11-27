# frozen_string_literal: true

# #543: the class body skips its concern's callback under a condition. A
# reload must not add the condition a second time, or `quiet?` runs twice.
class QuietNote < NoteBase
  include OwnStamps
  skip_callback :save, :before, :stamp, if: :quiet?

  def quiet? = (log << :quiet?) && false

  def stamp = log << :stamp

  def urgent?(level) = level > 2
end
