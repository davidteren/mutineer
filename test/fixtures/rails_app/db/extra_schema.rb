# frozen_string_literal: true

# Schema of the `extra` database (MUTINEER_SECOND_DB=1). Rails' DatabaseTasks
# finds it by the config name. Mutineer loads it into each worker's copy.
ActiveRecord::Schema.define(version: 1) do
  create_table :extra_notes, force: true do |t|
    t.string :body
  end
end
