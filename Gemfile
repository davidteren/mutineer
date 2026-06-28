# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# rspec is NOT a runtime/gemspec dependency — Mutineer requires it lazily only
# when --framework rspec is selected (it belongs to the TARGET project's bundle).
# It lives here purely so the test suite can exercise the RSpec test runner.
group :test do
  gem "rspec", "~> 3.0"
end
