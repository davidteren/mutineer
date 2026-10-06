# frozen_string_literal: true

class SingletonNestedApp
  class << self
    class Q
      def q1
        1 + 1
      end
    end

    P = Data.define do
      class Z
        def z1
          2 * 3
        end
      end
    end

    def q = Q.new.q1
    def z = Z.new.z1
  end
end
