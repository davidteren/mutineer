# frozen_string_literal: true

class NestedRedefineDepthFixture
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

NestedRedefineDepthFixture.new.a
