# frozen_string_literal: true

require "etc"
require "yaml"

module Mutineer
  # Raised by the config layer instead of calling exit/abort — a data class must
  # never kill the host process (R8). The CLI rescues this and maps it to exit 2.
  class ConfigError < StandardError; end

  # Plain run configuration, populated by the CLI (or directly by the
  # integration test). `operators` nil means "all default operators";
  # `threshold` 0.0 means the CI gate is off (spec §10).
  #
  # M5 adds: jobs (parallel workers), format (human|json), output (report file),
  # strategy (reload|redefine), require_paths (extra files to load). Config loading and
  # the CLI > file > default precedence merge live here (KTD3/KTD4).
  #
  # Boot mode adds: boot (a file to require ONCE in the parent so the app env —
  # e.g. Rails — is booted before forking; sources are then NOT manually required)
  # and rails (sugar: defaults boot to config/environment and strategy to redefine,
  # and reconnects ActiveRecord per fork).
  Config = Struct.new(
    :sources, :tests, :operators, :threshold, :only, :dry_run,
    :cache_dir, :project_root, :load_paths,
    :jobs, :format, :output, :strategy, :require_paths,
    :boot, :rails, :since, :framework, :verbose,
    keyword_init: true
  ) do
    CONFIG_FILE = ".mutineer.yml"
    # Keys accepted in .mutineer.yml (R7). `require` maps to the :require_paths field.
    KNOWN_KEYS = %w[operators jobs threshold only require boot rails since framework verbose].freeze

    def initialize(**kwargs)
      super
      self.sources       ||= []
      self.tests         ||= []
      self.threshold     ||= 0.0
      self.dry_run       ||= false
      self.cache_dir     ||= ".mutineer"
      self.project_root  ||= Dir.pwd
      self.load_paths    ||= ["lib"]
      self.jobs          ||= Etc.nprocessors
      self.format        ||= "human"
      self.strategy      ||= "reload"
      self.require_paths ||= []
      self.rails         = false if rails.nil?
      self.verbose       = false if verbose.nil?
    end

    # Walk from `start` toward `home`, returning the first .mutineer.yml path found
    # or nil. Checks `home` itself, then stops; if `start` is above `home`
    # (e.g. /tmp), the walk continues to the filesystem root (KTD4). Pure
    # discovery — reads no file content.
    def self.find_file(start = Dir.pwd, home = File.expand_path("~"))
      dir = File.expand_path(start)
      loop do
        candidate = File.join(dir, CONFIG_FILE)
        return candidate if File.file?(candidate)
        break if dir == home

        parent = File.dirname(dir)
        break if parent == dir # filesystem root

        dir = parent
      end
      nil
    end

    # Parse a .mutineer.yml into a symbol-keyed hash of recognized keys. Unknown
    # keys / unknown operator names emit a one-line stderr warning and are ignored
    # (R7). A YAML syntax error raises ConfigError (R7a/R8) — never a silent
    # fallback to defaults, and never an exit from the lib layer.
    def self.from_file(path)
      raw = YAML.safe_load(File.read(path)) || {}
      name = File.basename(path)
      unless raw.is_a?(Hash)
        warn "mutineer: #{name} ignored: expected a YAML mapping of keys to values"
        return {}
      end

      out = {}
      raw.each do |key, value|
        ks = key.to_s
        unless KNOWN_KEYS.include?(ks)
          warn "mutineer: unknown config key #{ks.inspect} in #{name} " \
               "(known: #{KNOWN_KEYS.join(', ')}); ignored"
          next
        end
        out[field_for(ks)] = coerce(ks, value, name)
      end
      out
    rescue Psych::SyntaxError => e
      raise ConfigError, "#{File.basename(path)} parse error: #{e.message}"
    end

    # Apply precedence (KTD3): start from the CLI-provided values, then fill in a
    # config-file value only for keys the user did NOT type on the command line.
    # `explicit` is a Set of field symbols the CLI saw with a value; a Set (not
    # nil-sentinels) is used because some valid values are zero/false.
    def self.resolve(cli_opts, file_hash, explicit)
      merged = cli_opts.dup
      file_hash.each { |k, v| merged[k] = v unless explicit.include?(k) }
      config = new(**merged)

      # --rails sugar: boot config/environment and prefer the surgical (redefine)
      # strategy, which avoids writing tempfiles into the app tree and Zeitwerk
      # reload hazards. An explicit --strategy always wins.
      if config.rails
        config.boot ||= "config/environment"
        config.strategy = "redefine" unless explicit.include?(:strategy)
        # #12: parallel mutant forks share one database; transactional-fixture
        # setup/teardown across processes contends and deadlocks. Default to
        # serial under --rails; an explicit --jobs N opts back into parallelism
        # (with the per-worker DB-isolation that implies).
        config.jobs = 1 unless explicit.include?(:jobs)
      end

      # Auto-detect the framework only when neither CLI nor config file set it
      # (explicit value, from either source, is already on config.framework and
      # always wins). Default minitest unless the test files clearly look RSpec.
      config.framework ||= detect_framework(config.tests)
      config
    end

    # Pick rspec when a MAJORITY of the given test files end with _spec.rb;
    # otherwise minitest. Empty/ambiguous -> minitest (the safe default).
    def self.detect_framework(tests)
      tests = Array(tests)
      specs = tests.count { |t| t.to_s.end_with?("_spec.rb") }
      specs > tests.length / 2.0 ? "rspec" : "minitest"
    end

    def self.field_for(known_key)
      known_key == "require" ? :require_paths : known_key.to_sym
    end

    def self.coerce(known_key, value, file_name)
      case known_key
      when "operators" then filter_operators(Array(value).map(&:to_s), file_name)
      when "jobs"      then value.to_i
      when "threshold" then value.to_f
      when "require"   then Array(value).map(&:to_s)
      when "boot"      then value.to_s
      when "framework" then value.to_s
      when "rails"     then value == true || value.to_s == "true"
      when "verbose"   then value == true || value.to_s == "true"
      else value
      end
    end

    # Drop (with a warning) operator names the registry doesn't know (R7).
    # Referenced lazily so config.rb carries no load-order dependency on the
    # registry; by the time a config is parsed at runtime, it is loaded.
    def self.filter_operators(names, file_name)
      known = MutatorRegistry::ALL.keys
      names.select do |n|
        next true if known.include?(n)

        warn "mutineer: unknown operator #{n.inspect} in #{file_name} " \
             "(known: #{known.join(', ')}); ignored"
        false
      end
    end
  end
end
