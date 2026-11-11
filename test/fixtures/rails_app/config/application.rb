# frozen_string_literal: true

require_relative "boot"

require "rails"
# Minimal Rails: only ActiveRecord (+ ActiveSupport, pulled in). No web stack —
# the point is to dogfood Mutineer's --rails boot, Zeitwerk autoloading, and
# per-fork ActiveRecord/transactional-fixture handling, not to serve requests.
require "active_record/railtie"

module Dummy
  class Application < Rails::Application
    config.load_defaults 7.1
    config.root = File.expand_path("..", __dir__)
    # MUTINEER_EAGER_LOAD=1 loads every class at boot, as production apps
    # often do, so a reload of a parent reaches loaded subclasses (#414).
    config.eager_load = ENV["MUTINEER_EAGER_LOAD"] == "1"
    # Schema is loaded explicitly from db/schema.rb (no migrations dir), so skip
    # Rails' pending-migration check that would otherwise abort the suite.
    # MUTINEER_MAINTAIN_SCHEMA=1 turns it on, as in a new Rails app (#385).
    config.active_record.maintain_test_schema = ENV["MUTINEER_MAINTAIN_SCHEMA"] == "1"
  end
end
