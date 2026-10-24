# frozen_string_literal: true

# MUTINEER_EXTRA_POOL=1 (with MUTINEER_SECOND_DB=1) registers a pool for the
# `extra` database, as an app with a solid_cable `connects_to` in test does.
# Transactional tests then connect that pool in every test, so a parallel run
# that lists `extra` in shared_databases must score every mutant `error`.
# ExtraNote writes to `extra` (its table comes from db/extra_schema.rb).
if ENV["MUTINEER_EXTRA_POOL"] == "1"
  class ExtraRecord < ActiveRecord::Base
    self.abstract_class = true
    connects_to database: { writing: :extra }
  end

  class ExtraNote < ExtraRecord
  end
end
