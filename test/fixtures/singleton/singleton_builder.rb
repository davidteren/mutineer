# frozen_string_literal: true

class SingletonBuilderApp
  class << self
    Point = Data.define(:x) do
      def m
        x * 2
      end
    end

    def point(x)
      Point.new(x: x)
    end
  end
end
