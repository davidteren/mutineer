# frozen_string_literal: true

require "test_helper"

class LedgerRowTest < ActiveSupport::TestCase
  def test_zero
    assert LedgerRow.new(0).zero?
    refute LedgerRow.new(5).zero?
  end

  def test_single
    assert LedgerRow::Line.new(1).single?
    refute LedgerRow::Line.new(2).single?
    assert_same LedgerRow::LINE_BASE, LedgerRow::Line.superclass
  end
end
