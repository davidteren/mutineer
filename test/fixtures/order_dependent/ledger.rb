# frozen_string_literal: true

# Process-wide state that two tests share, so their order matters (#338).
module Ledger
  # @return [Array<Integer>] amounts recorded so far in this process.
  def self.entries
    @entries ||= []
  end

  # @param amount [Integer]
  # @return [Array<Integer>]
  def self.record(amount)
    entries << amount
  end

  # @return [Integer]
  def self.total
    entries.inject(0) { |sum, amount| sum + amount }
  end
end
