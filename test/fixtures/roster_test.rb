# frozen_string_literal: true

require "minitest/autorun"
require_relative "roster"

# Deliberately lists active members only. So dropping `.select(&:active)`
# survives undetected — nothing checks that an inactive member is left out.
class RosterTest < Minitest::Test
  def test_active_names_sorted
    roster = Roster.new([Roster::Member.new("Grace", true), Roster::Member.new("Ada", true)])
    assert_equal %w[Ada Grace], roster.active_names
  end
end
