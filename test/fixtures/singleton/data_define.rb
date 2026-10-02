# frozen_string_literal: true

module DataDefineOuter
  SCALE = 3

  Point = Data.define(:x) do
    def scaled
      x * SCALE
    end
  end
end

DataDefinePair = Struct.new(:a, :b) do
  def self.sum(a, b)
    a + b
  end
end
