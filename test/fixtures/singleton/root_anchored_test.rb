# frozen_string_literal: true

require "minitest/autorun"
require_relative "root_anchored"

# Deliberately weak: it only checks the type, so arithmetic mutants survive under
# reload. Redefine must report the same survivors, not NameError "kills" (#145).
class RootAnchoredTest < Minitest::Test
  def test_scale_returns_a_number
    assert_kind_of Integer, RootTop.new.scale(3)
  end
end
