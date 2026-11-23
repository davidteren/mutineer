# frozen_string_literal: true

require "minitest/autorun"
require_relative "local_read_superclass"

class LocalReadSuperclassTest < Minitest::Test
  def test_in_block_through_the_subclass
    assert LocalRow.new(1).in_block?
    refute LocalRow.new(2).in_block?
  end

  def test_three_runs
    LocalRow.new(3).three?
  end
end
