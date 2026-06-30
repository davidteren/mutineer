# frozen_string_literal: true

# The entry point `--rails` boots (sugar for `--boot config/environment`).
require_relative "application"
Rails.application.initialize!
