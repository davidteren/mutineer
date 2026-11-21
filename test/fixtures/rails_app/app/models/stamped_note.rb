# frozen_string_literal: true

# #479: the concern and the class body add the same `&:stamp` callback. Reload
# cannot tell which old copy the new one repeats, so it keeps both, and the run
# warns that this class runs a callback more than once.
class StampedNote < NoteBase
  include Stamps
  before_save(&:stamp)

  def stamp = log << :stamp

  def urgent?(level) = level > 2
end
