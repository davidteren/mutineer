# frozen_string_literal: true

class Deep
  def a
    def b
      def c
        1 + 1
      end
      c
    end
    :a
  end
end

Deep.new.a
