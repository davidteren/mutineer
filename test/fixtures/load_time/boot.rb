# frozen_string_literal: true

# Stands in for config/environment: booting loads Catalog, so its class body
# (and the `price` call in it) runs before any test.
require_relative "lib/catalog"
