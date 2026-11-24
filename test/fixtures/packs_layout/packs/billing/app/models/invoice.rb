# frozen_string_literal: true

# #494: a pack source with no test anywhere. It stays unpaired.
class Invoice
  def due(amount, fee)
    amount + fee
  end
end
