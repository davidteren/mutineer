# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# rspec is NOT a runtime/gemspec dependency — Mutineer requires it lazily only
# when --framework rspec is selected (it belongs to the TARGET project's bundle).
# It lives here purely so the test suite can exercise the RSpec test runner.
group :test do
  # Minitest 5 here; gemfiles/minitest6.gemfile runs the suite on Minitest 6.
  # The stop at the first failure has separate hooks for each major version.
  gem "minitest", "~> 5.0"
  gem "rspec", "~> 3.0"
end
