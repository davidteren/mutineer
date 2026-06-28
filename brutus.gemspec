# frozen_string_literal: true

require_relative "lib/brutus/version"

Gem::Specification.new do |spec|
  spec.name          = "brutus"
  spec.version       = Brutus::VERSION
  spec.authors       = ["David Teren"]
  spec.summary       = "A clean-room mutation-testing tool for Ruby (Prism + stdlib only)."
  spec.description   = "Brutus mutates your source and runs your Minitest suite to find tests " \
                       "that don't actually test anything. Prism-based, zero runtime dependencies."
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir.glob("lib/**/*.rb") + ["README.md", "brutus.gemspec"]
  spec.bindir      = "bin"
  spec.executables = ["brutus"]
  spec.require_paths = ["lib"]

  # No runtime dependencies — Prism is bundled with Ruby >= 3.4.
  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
end
