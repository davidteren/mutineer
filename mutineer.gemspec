# frozen_string_literal: true

require_relative "lib/mutineer/version"

Gem::Specification.new do |spec|
  spec.name          = "mutineer"
  spec.version       = Mutineer::VERSION
  spec.authors       = ["David Teren"]
  spec.email         = ["dteren@gmail.com"]
  spec.summary       = "A clean-room mutation-testing tool for Ruby (Prism + stdlib only)."
  spec.description   = "Mutineer mutates your source one change at a time and runs your Minitest or RSpec " \
                       "suite against each mutant to find tests that don't actually test anything. " \
                       "Prism-based, fork-isolated, zero runtime dependencies."
  spec.homepage      = "https://github.com/davidteren/mutineer"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "https://davidteren.github.io/mutineer/",
    "rubygems_mfa_required" => "true",
    # Rails Hyperdrive companion opt-in: `bin/rails hyperdrive:init` copies the
    # shipped skills/ into an app that bundles mutineer. "*" matches every app.
    "hyperdrive_targets" => "*",
    # Display hint for `bin/rails hyperdrive:discover` ("ships skill"); not an opt-in.
    "hyperdrive_artifacts" => "skill"
  }

  # bin/mutineer MUST be shipped, else the declared executable has no source file.
  # skills/ holds the agent skill that Rails Hyperdrive installs (see metadata above).
  spec.files       = Dir.glob("lib/**/*.rb") + Dir.glob("bin/*") + Dir.glob("skills/**/*") + %w[README.md LICENSE CHANGELOG.md]
  spec.bindir      = "bin"
  spec.executables = ["mutineer"]
  spec.require_paths = ["lib"]

  # No runtime dependencies — Prism is bundled with Ruby >= 3.4.
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "yard", "~> 0.9"
end
