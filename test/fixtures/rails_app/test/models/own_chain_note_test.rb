# frozen_string_literal: true

require "test_helper"

class OwnChainNoteTest < ActiveSupport::TestCase
  def test_save_runs_the_concern_and_the_body_callback
    assert_equal %i[stamp own], OwnChainNote.new.save
  end

  # Runs `urgent?` with no assertion, so each of its mutants must survive.
  def test_urgent_runs
    OwnChainNote.new.urgent?(3)
  end
end
