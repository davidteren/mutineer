# frozen_string_literal: true

require "minitest/autorun"
require_relative "local_superclass"

class LocalSuperclassTest < Minitest::Test
  def test_four
    assert Quad.new(4).four?
    refute Quad.new(3).four?
    # A lost or new local would make this false for every mutant.
    assert_same QUAD_BASE, Quad.superclass
  end

  def test_five
    assert Plain.new(5).five?
    refute Plain.new(4).five?
    assert_same PLAIN_BASE, Plain.superclass
  end
end
