# frozen_string_literal: true

require "test_helper"

# Needs MUTINEER_SECOND_DB=1 and MUTINEER_EXTRA_POOL=1. Commits a row to the
# `extra` database outside a transaction. A worker that shares `extra` with
# another worker sees that worker's row, and this test fails.
class ExtraNoteTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def test_extra_database_starts_empty
    assert_equal 0, ExtraNote.count
    ExtraNote.create!(body: "committed")
  end
end
