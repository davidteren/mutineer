# frozen_string_literal: true

# Skips its parent's callback, so it saves with no weight (#414).
class FreePostage < Postage
  self.table_name = "shipments"

  skip_callback :save, :before, :require_weight
end
