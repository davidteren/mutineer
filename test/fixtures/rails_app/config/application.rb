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
    config.eager_load = false
    # Schema is loaded explicitly from db/schema.rb (no migrations dir), so skip
    # Rails' pending-migration check that would otherwise abort the suite.
    config.active_record.maintain_test_schema = false
  end
end
