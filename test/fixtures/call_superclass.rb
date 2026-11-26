# frozen_string_literal: true

# #492: a class whose superclass is a call. Each evaluation of `Data.define`
# builds a new class, so loading this file again raised "superclass mismatch".
class InclusionValue < Data.define(:type, :value)
  def switch? = type == "switch"

  def weak? = type == "weak"
end

module Billing
  class Money < Struct.new(:cents, keyword_init: true)
    def zero? = cents == 0
  end
end
