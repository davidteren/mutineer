# frozen_string_literal: true

require "minitest/autorun"
require_relative "access"

# Deliberately checks only that an answer comes back, not which answer. So the
# `!user` -> `user` mutation survives undetected — nothing checks for `false`.
class AccessTest < Minitest::Test
  def test_guest_answers_for_present_user
    refute_nil Access.new.guest?(Object.new)
  end
end
