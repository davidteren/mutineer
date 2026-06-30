# frozen_string_literal: true

module SingletonClassSelf
  class << self
    def calc(a, b)
      a + b
    end
  end
end
