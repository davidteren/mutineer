# frozen_string_literal: true

require "test_helper"

class HelperChainNoteTest < ActiveSupport::TestCase
  # A halted save skips the after callback only while the chain keeps
  # `skip_after_callbacks_if_terminated: true`.
  def test_a_halted_save_skips_the_after_callback
    note = HelperChainNote.new
    note.save
    assert_empty note.log
  end
end
