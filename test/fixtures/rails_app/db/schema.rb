# frozen_string_literal: true

# Loaded (idempotently, force: true) by test_helper before the suite runs. No
# migrations dir — this single schema file is the source of truth for the
# fixture DB.
ActiveRecord::Schema.define(version: 1) do
  create_table :orders, force: true do |t|
    t.integer :quantity, null: false, default: 0
    t.integer :unit_price_cents, null: false, default: 0
    t.boolean :rush, null: false, default: false
    t.timestamps
  end
end
