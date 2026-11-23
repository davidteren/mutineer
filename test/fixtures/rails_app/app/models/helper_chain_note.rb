# frozen_string_literal: true

# #504: the class body defines its chain through a helper. A reload skips a
# chain the class already has, with the options the helper passes, so a
# mutant in the helper never reaches Rails.
class HelperChainNote
  include ActiveSupport::Callbacks

  def self.note_callbacks(name)
    define_callbacks name, skip_after_callbacks_if_terminated: true
  end
  note_callbacks :save

  set_callback(:save, :before) { throw :abort }
  set_callback(:save, :after) { |note| note.log << :after }

  def log = (@log ||= [])

  def save = run_callbacks(:save) { log << :saved }
end
