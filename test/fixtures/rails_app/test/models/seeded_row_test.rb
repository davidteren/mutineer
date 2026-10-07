# frozen_string_literal: true

require "test_helper"

# Needs the --require file test/support/seed_setup.rb (#222).
class SeededRowTest < ActiveSupport::TestCase
  def test_seeded_row
    assert_equal ["from boot"], ActiveRecord::Base.connection.select_values("SELECT name FROM seeded_rows")
  end

  def test_round
    assert_equal 7, TaxTable.round(6)
  end
end
