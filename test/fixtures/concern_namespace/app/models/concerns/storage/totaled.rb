# frozen_string_literal: true

module Storage
  module Totaled
    def total(used, reserved)
      used + reserved
    end
  end
end
