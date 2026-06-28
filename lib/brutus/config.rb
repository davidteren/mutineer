# frozen_string_literal: true

module Brutus
  # Plain run configuration, populated by the CLI (or directly by the
  # integration test). `operators` nil means "all default operators";
  # `threshold` 0.0 means the CI gate is off (spec §10).
  Config = Struct.new(
    :sources, :tests, :operators, :threshold, :only, :dry_run,
    :cache_dir, :project_root, :load_paths,
    keyword_init: true
  ) do
    def initialize(**kwargs)
      super
      self.sources      ||= []
      self.tests        ||= []
      self.threshold    ||= 0.0
      self.dry_run      ||= false
      self.cache_dir    ||= ".brutus"
      self.project_root ||= Dir.pwd
      self.load_paths   ||= ["lib"]
    end
  end
end
