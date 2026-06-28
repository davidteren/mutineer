# frozen_string_literal: true

require_relative "lib/mutineer/version"

Gem::Specification.new do |spec|
  spec.name          = "mutineer"
  spec.version       = Mutineer::VERSION
  spec.authors       = ["David Teren"]
  spec.email         = ["dteren@gmail.com"]
  spec.summary       = "A clean-room mutation-testing tool for Ruby (Prism + stdlib only)."
  spec.description   = "Mutineer mutates your source one change at a time and runs your Minitest " \
                       "suite against each mutant to find tests that don't actually test anything. " \
                       "Prism-based, fork-isolated, zero runtime dependencies."
  spec.homepage      = "https://github.com/davidteren/mutineer"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  # bin/mutineer MUST be shipped, else the declared executable has no source file.
  spec.files       = Dir.glob("lib/**/*.rb") + Dir.glob("bin/*") + %w[README.md LICENSE CHANGELOG.md]
  spec.bindir      = "bin"
  spec.executables = ["mutineer"]
  spec.require_paths = ["lib"]

  # No runtime dependencies — Prism is bundled with Ruby >= 3.4.
  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
end
