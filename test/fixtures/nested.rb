# frozen_string_literal: true

class Nested
  def outer
    def inner
      1 + 1
    end
    inner
  end
end
