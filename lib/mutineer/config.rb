# frozen_string_literal: true

require "etc"
require "yaml"
require "set"

module Mutineer
  # Raised by the config layer instead of calling exit/abort — a data class must
  # never kill the host process (R8). The CLI rescues this and maps it to exit 2.
  class ConfigError < StandardError; end

  # Plain run configuration, populated by the CLI (or directly by the
  # integration test). `operators` nil means "all default operators";
  # `threshold` 0.0 means the CI gate is off (spec §10).
  #
  # M5 adds: jobs (parallel workers), format (human|json), output (report file),
  # strategy (7a|7b), require_paths (extra files to load). Config-file loading and
  # the CLI > file > default precedence merge live here (KTD3/KTD4).
  Config = Struct.new(
    :sources, :tests, :operators, :threshold, :only, :dry_run,
    :cache_dir, :project_root, :load_paths,
    :jobs, :format, :output, :strategy, :require_paths,
    keyword_init: true
  ) do
    CONFIG_FILE = ".mutineer.yml"
    # Keys accepted in .mutineer.yml (R7). `require` maps to the :require_paths field.
    KNOWN_KEYS = %w[operators jobs threshold only require].freeze

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
      self.strategy      ||= "7a"
      self.require_paths ||= []
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
      new(**merged)
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
