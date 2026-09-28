# frozen_string_literal: true

class Discount
  def eligible?(member, total)
    member && total >= 100
  end
end
