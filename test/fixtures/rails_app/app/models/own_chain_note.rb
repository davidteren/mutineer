# frozen_string_literal: true

# #504: the class body defines its own chain. A reload must not clear it, or
# the concern's `stamp` callback is lost.
class OwnChainNote
  include ActiveSupport::Callbacks
  define_callbacks :save

  def self.before_save(*args, &block) = set_callback(:save, :before, *args, &block)

  include OwnStamps
  before_save { |note| note.log << :own }

  def log = (@log ||= [])

  def stamp = log << :stamp

  def save = run_callbacks(:save) { log }

  def urgent?(level) = level > 2
end
