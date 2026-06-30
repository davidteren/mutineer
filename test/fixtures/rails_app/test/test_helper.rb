# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# No migrations dir — load the schema directly (force: true makes it idempotent),
# so the test DB exists both for the suite and for Mutineer's forked coverage
# capture, which loads this helper.
load File.expand_path("../db/schema.rb", __dir__)

module ActiveSupport
  class TestCase
    # Real transactional fixtures (the default): each test runs inside a
    # transaction that is rolled back. This is precisely the path Mutineer's
    # per-fork `reconnect_active_record` must not clobber (#8).
    fixtures :all
  end
end
