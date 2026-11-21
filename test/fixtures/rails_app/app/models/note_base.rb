# frozen_string_literal: true

# #479: owns the :save chain, so a reload of a subclass file does not reset it.
class NoteBase
  include ActiveSupport::Callbacks
  define_callbacks :save

  def self.before_save(*args, &block) = set_callback(:save, :before, *args, &block)

  def log = (@log ||= [])

  def save = run_callbacks(:save) { log }
end
