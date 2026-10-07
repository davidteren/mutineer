# frozen_string_literal: true

# Stands in for config/environment: booting loads Shelf, so its class body
# (and the calls in it) runs before any test.
require_relative "lib/shelf"
