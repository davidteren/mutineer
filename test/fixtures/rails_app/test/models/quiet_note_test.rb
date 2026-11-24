# frozen_string_literal: true

require "test_helper"

class QuietNoteTest < ActiveSupport::TestCase
  def test_save_asks_quiet_once
    assert_equal %i[quiet? stamp], QuietNote.new.save
  end

  # Runs `urgent?` with no assertion, so each of its mutants must survive.
  def test_urgent_runs
    QuietNote.new.urgent?(3)
  end
end
