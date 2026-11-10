# frozen_string_literal: true

# Skips its parent's callback only for express parcels (#414).
class ExpressPostage < Postage
  self.table_name = "shipments"

  skip_callback :save, :before, :require_weight, if: :express?
end
