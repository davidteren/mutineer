# frozen_string_literal: true

require "test_helper"

class StampedNoteTest < ActiveSupport::TestCase
  def test_urgent
    assert StampedNote.new.urgent?(3)
    refute StampedNote.new.urgent?(2)
  end
end
