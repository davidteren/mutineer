# frozen_string_literal: true

require "did_you_mean"
require "etc"
require "yaml"

module Mutineer
  # A "did you mean" hint for a misspelled name, using the stdlib spell
  # checker that Ruby itself uses for NameError.
  #
  # @param word [String] the name the user wrote.
  # @param candidates [Array<String>] the names that are valid here.
  # @return [String] ` (did you mean "x"?)` for the closest candidate, or "" when none is close.
  def self.did_you_mean(word, candidates)
    match = DidYouMean::SpellChecker.new(dictionary: candidates).correct(word.to_s).first
    match ? " (did you mean #{match.inspect}?)" : ""
  end

  # Raised by the config layer instead of calling exit/abort. A data class must
  # never kill the host process. The CLI rescues this and maps it to exit 2.
  class ConfigError < StandardError; end

  # One row of the option schema: how a Config field is parsed and where the
  # user can set it. `yaml_key` is nil for CLI-only options; `flag` is nil for
  # YAML-only ones. `values`/`aliases` apply to the :enum type.
  #
  # @api private
  ConfigOption = Struct.new(:field, :type, :yaml_key, :flag, :values, :aliases, keyword_init: true)

  # Deprecated internal strategy names, mapped to their canonical equivalents.
  STRATEGY_ALIASES = { "7a" => "reload", "7b" => "redefine" }.freeze

  # The option schema. Config.parse is the only place that turns a raw value
  # (a CLI string or a YAML scalar) into a typed one, so a value is checked once,
  # at the boundary, whichever layer wrote it. Row order fixes the order of
  # KNOWN_KEYS in warnings.
  #
  # @api private
  CONFIG_OPTIONS = [
    ConfigOption.new(field: :operators, type: :string_list, yaml_key: "operators", flag: "--operators"),
    ConfigOption.new(field: :jobs, type: :positive_int, yaml_key: "jobs", flag: "--jobs"),
    ConfigOption.new(field: :threshold, type: :percent, yaml_key: "threshold", flag: "--threshold"),
    ConfigOption.new(field: :only, type: :string, yaml_key: "only", flag: "--only"),
    ConfigOption.new(field: :require_paths, type: :string_list, yaml_key: "require"),
    ConfigOption.new(field: :boot, type: :string, yaml_key: "boot", flag: "--boot"),
    ConfigOption.new(field: :rails, type: :bool, yaml_key: "rails", flag: "--rails"),
    ConfigOption.new(field: :since, type: :since, yaml_key: "since", flag: "--since"),
    ConfigOption.new(field: :framework, type: :enum, yaml_key: "framework", flag: "--framework",
                     values: %w[minitest rspec]),
    ConfigOption.new(field: :verbose, type: :bool, yaml_key: "verbose", flag: "--verbose"),
    ConfigOption.new(field: :ignore, type: :ignore_list, yaml_key: "ignore"),
    ConfigOption.new(field: :baseline, type: :string, yaml_key: "baseline", flag: "--baseline"),
    ConfigOption.new(field: :fail_fast, type: :bool, yaml_key: "fail_fast", flag: "--fail-fast"),
    ConfigOption.new(field: :matrix, type: :bool, yaml_key: "matrix", flag: "--matrix"),
    ConfigOption.new(field: :test_command, type: :string, yaml_key: "test_command", flag: "--test-command"),
    ConfigOption.new(field: :daemon, type: :bool, yaml_key: "daemon", flag: "--daemon"),
    ConfigOption.new(field: :timeout, type: :positive_int, yaml_key: "timeout", flag: "--timeout"),
    ConfigOption.new(field: :capture_timeout, type: :positive_int, yaml_key: "capture_timeout",
                     flag: "--capture-timeout"),
    ConfigOption.new(field: :cache_dir, type: :string, yaml_key: "cache_dir", flag: "--cache-dir"),
    ConfigOption.new(field: :allow_empty, type: :bool, yaml_key: "allow_empty", flag: "--allow-empty"),
    ConfigOption.new(field: :format, type: :enum, flag: "--format", values: %w[human json html]),
    ConfigOption.new(field: :strategy, type: :enum, flag: "--strategy", values: %w[reload redefine],
                     aliases: STRATEGY_ALIASES),
    ConfigOption.new(field: :output, type: :string, flag: "--output"),
    ConfigOption.new(field: :baseline_epsilon, type: :nonneg_float, flag: "--baseline-epsilon"),
    ConfigOption.new(field: :dry_run, type: :bool, flag: "--dry-run")
  ].freeze

  # Plain run configuration, populated by the CLI (or directly by the
  # integration test). `operators` nil means "all default operators";
  # `threshold` 0.0 means the CI gate is off (spec §10).
  #
  # Also holds: jobs (parallel workers), format (human|json), output (report
  # file), strategy (reload|redefine), require_paths (extra files to load).
  # Config loading and the CLI > file > default precedence merge live here; each
  # layer holds only the keys the user wrote, and Config#explicit? reports them.
  #
  # `matrix` (--matrix) runs every covering test for each mutant and reports
  # which tests kill it (see KillMatrix); it never changes a verdict.
  #
  # Boot mode adds: boot (a file to require ONCE in the parent so the app env,
  # e.g. Rails, is booted before forking; sources are then NOT manually required)
  # and rails (sugar: defaults boot to config/environment, prefers redefine without
  # a daemon, and reconnects ActiveRecord per fork).
  Config = Struct.new(
    :sources, :tests, :operators, :threshold, :only, :dry_run,
    :cache_dir, :project_root, :load_paths,
    :jobs, :format, :output, :strategy, :require_paths,
    :boot, :rails, :since, :framework, :verbose, :ignore, :ignore_reasons,
    # :daemon is user-facing (--daemon flag + KNOWN_KEYS + boolean coerce).
    # :daemon_timeout stays programmatic (set by tests/Runner; no flag yet).
    :baseline, :baseline_epsilon, :fail_fast, :test_command,
    :daemon, :daemon_timeout, :timeout, :capture_timeout, :matrix, :allow_empty,
    keyword_init: true
  ) do
    # Config file name.
    CONFIG_FILE = ".mutineer.yml"
    # Keys accepted in .mutineer.yml, derived from the schema. `require` maps to the
    # :require_paths field.
    KNOWN_KEYS = CONFIG_OPTIONS.filter_map(&:yaml_key).freeze

    # @param explicit [Array<Symbol>] fields the user wrote (CLI or file). Derived
    #   values fill only the others; a programmatic Config.new writes none.
    # @param from_file [Array<Symbol>] the explicit fields whose value came from
    #   the config file (the command line did not override them).
    def initialize(explicit: [], from_file: [], **kwargs)
      super(**kwargs)
      @explicit = explicit.to_a.dup.freeze
      @from_file = from_file.to_a.dup.freeze
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
      self.ignore        ||= []
      self.ignore_reasons ||= {}
      self.baseline_epsilon ||= 0.0
      self.fail_fast     = false if fail_fast.nil?
      self.daemon        = false if daemon.nil?
      self.matrix        = false if matrix.nil?
      self.allow_empty   = false if allow_empty.nil?
    end

    # True when the user wrote `key`, on the command line or in the config
    # file, whatever the value (`false` and `nil` count). The answer comes from
    # which keys the layers held, so a new option needs no bookkeeping to be
    # covered.
    #
    # @param key [Symbol] Config field name.
    # @return [Boolean]
    def explicit?(key)
      @explicit.include?(key)
    end

    # Where the user set `key`, for messages: the config-file key (as
    # `name in .mutineer.yml`) when its value came from the file, else the
    # command-line flag.
    #
    # @param key [Symbol] Config field name (a row of the option schema).
    # @return [String] e.g. `"--fail-fast"` or `"fail_fast in .mutineer.yml"`.
    def origin(key)
      opt = CONFIG_OPTIONS.find { |o| o.field == key } or raise ArgumentError, "unknown option #{key.inspect}"
      @from_file.include?(key) && opt.yaml_key ? "#{opt.yaml_key} in #{CONFIG_FILE}" : (opt.flag || opt.yaml_key)
    end

    # Walk from `start` toward `home`, returning the first .mutineer.yml path found
    # or nil. Checks `home` itself, then stops; if `start` is above `home`
    # (e.g. /tmp), the walk continues to the filesystem root. Pure discovery;
    # reads no file content.
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

    # Parse a .mutineer.yml into a symbol-keyed hash of recognized keys. An
    # unknown key raises {ConfigError}. An unknown operator name raises
    # {ConfigError} unless +defer_operators+ is set, in which case unknown names
    # are dropped because the command line replaces the list. A blank operator
    # list is an error unless +defer_operators+ is set: an empty list would run
    # nothing. A YAML syntax error raises ConfigError: never a silent fallback
    # to defaults, and never an exit from the lib layer.
    #
    # @param path [String] config file path.
    # @param defer_operators [Boolean] keep an empty operator list for a CLI override.
    # @return [Hash{Symbol => Object}]
    def self.from_file(path, defer_operators: false)
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
          raise ConfigError, "#{name}: unknown config key #{ks.inspect}" \
                             "#{Mutineer.did_you_mean(ks, KNOWN_KEYS)} (known: #{KNOWN_KEYS.join(', ')})"
        end
        field = field_for(ks)
        parsed = parse(field, value, file: name, defer_operators: defer_operators)
        if field == :ignore
          out[:ignore] = parsed.fetch(:ids)
          out[:ignore_reasons] = parsed.fetch(:reasons)
          next
        end
        if field == :operators
          parsed = filter_operators(parsed, name, strict: !defer_operators)
          if parsed.empty? && !defer_operators
            raise ConfigError, "#{name}: operators must name at least one known operator"
          end
        end
        out[field] = parsed
      end
      out
    rescue Psych::SyntaxError => e
      raise ConfigError, "#{File.basename(path)} parse error: #{e.message}"
    end

    # Merges the two user layers, CLI over file, then derives what neither wrote.
    # A layer is a Hash of only the keys the user set, so precedence is `merge`
    # and "did the user write this" is whether the key exists. Nothing tracks
    # provenance by hand, and `false`/`nil` are ordinary values.
    #
    # @param cli_opts [Hash{Symbol => Object}] parsed command-line fields.
    # @param file_hash [Hash{Symbol => Object}] parsed .mutineer.yml fields.
    # @return [Mutineer::Config]
    def self.resolve(cli_opts, file_hash)
      user = file_hash.merge(cli_opts)
      config = new(**user, explicit: user.keys, from_file: file_hash.keys - cli_opts.keys)

      # --rails sugar: boot config/environment. Prefer redefine only for the
      # in-process path (daemon is whole-file reload only). In-process --rails
      # shares one test database, so force serial unless --daemon.
      if config.rails
        config.boot ||= "config/environment"
        unless config.daemon || config.explicit?(:strategy)
          config.strategy = "redefine"
        end
        unless config.daemon
          # A typed --no-daemon already chose the serial run; only an explicit
          # --jobs N still needs telling that --daemon is the way to get N.
          if config.jobs.to_i > 1 && (!config.explicit?(:daemon) || config.explicit?(:jobs))
            warn "[mutineer] --rails without --daemon runs serially (shared test DB); " \
                 "forcing --jobs 1. Use --daemon for safe --jobs N."
          end
          config.jobs = 1
        end
      end

      # Auto-detect the framework only when the user wrote none: a value from
      # either layer is already on config.framework and always wins. Default
      # minitest unless the test files clearly look RSpec.
      config.framework ||= detect_framework(config.tests)
      config
    end

    # Mutineer 2.0 makes the daemon the default under --rails for Minitest, so a
    # run that would change says so now. The CLI calls this after test pairing,
    # which can still switch the framework to rspec. The runs that 2.0 keeps on this path
    # stay quiet: RSpec, --test-command, --matrix and --fail-fast cannot use the
    # daemon, a --dry-run runs no tests, and a written `daemon` value (true or
    # false) is the user's choice.
    #
    # @api private
    # @param config [Mutineer::Config] the resolved config.
    # @return [void]
    def self.warn_rails_default_change(config)
      return unless config.rails && !config.explicit?(:daemon) && config.framework == "minitest"
      return if config.test_command || config.matrix || config.fail_fast || config.dry_run

      warn "[mutineer] in Mutineer 2.0, --rails uses --daemon by default: parallel workers (unless " \
           "--jobs 1) and the reload strategy. Pass --no-daemon (or daemon: false) to keep this run as it is."
    end

    # Pick rspec when a MAJORITY of the given test files end with _spec.rb;
    # otherwise minitest. Empty/ambiguous -> minitest (the safe default).
    #
    # @param tests [Array<String>] test file paths.
    # @return [String] `"rspec"` or `"minitest"`.
    def self.detect_framework(tests)
      tests = Array(tests)
      specs = tests.count { |t| t.to_s.end_with?("_spec.rb") }
      specs > tests.length / 2.0 ? "rspec" : "minitest"
    end

    # Maps a config key to its Struct field.
    #
    # @param known_key [String] config key.
    # @return [Symbol] struct field name.
    def self.field_for(known_key)
      known_key == "require" ? :require_paths : known_key.to_sym
    end

    # Parses one raw value into the typed value for `field`. A value that does
    # not fit its type raises ConfigError naming where it came from, so the CLI
    # and .mutineer.yml report the same mistake in the same way. `nil` and
    # `false` are valid results for some fields (`since: false` means "no scoping").
    #
    # @param field [Symbol] Config field name (a row of the option schema).
    # @param value [Object] raw CLI string or YAML value.
    # @param file [String, nil] config file name when the value came from it;
    #   nil when it came from the command line.
    # @param defer_operators [Boolean] when true, a blank operator list is
    #   returned instead of raising, so +--operators+ can replace it. The flag
    #   itself still rejects a blank list.
    # @return [Object] the typed value.
    # @raise [Mutineer::ConfigError] when the value does not fit the field's type.
    def self.parse(field, value, file: nil, defer_operators: false)
      opt = CONFIG_OPTIONS.find { |o| o.field == field } or raise ArgumentError, "unknown option #{field.inspect}"
      origin = file ? "#{file}: #{opt.yaml_key}" : opt.flag
      got = "(got: #{value.inspect})"
      case opt.type
      when :positive_int
        n = value.is_a?(Integer) ? value : (value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/))
        raise ConfigError, "#{origin} must be a positive integer, digits only #{got}" if n.nil? || n < 1

        n
      when :percent
        f = finite_float(value)
        raise ConfigError, "#{origin} must be a number between 0 and 100 #{got}" unless f && (0.0..100.0).cover?(f)

        f
      when :nonneg_float
        f = finite_float(value)
        raise ConfigError, "#{origin} must be a finite number, 0 or greater #{got}" unless f && f >= 0.0

        f
      when :bool
        return value if [true, false].include?(value)
        return value == "true" if %w[true false].include?(value)

        raise ConfigError, "#{origin} must be true or false #{got}"
      when :enum
        name = opt.aliases&.fetch(value, nil) || value
        return name if opt.values.include?(name)

        prefix = file ? "#{file}: " : ""
        raise ConfigError, "#{prefix}unknown #{field} #{value.to_s.inspect}. Expected: #{opt.values.join(', ')}"
      when :ignore_list
        parse_ignore_list(value, file)
      when :string_list
        items = Array(value).map(&:to_s)
        # Only `operators` treats [] as "run these" rather than "use the
        # default". A blank key then makes no mutants and exits 0. An empty
        # `require` or `ignore` matches the default, so those stay valid.
        if field == :operators && !defer_operators && ([nil, true, false].include?(value) || items.empty? || items.all? { |item| item.strip.empty? })
          raise ConfigError, "#{origin} must name at least one operator, not blank #{got}"
        end

        items
      when :string
        # A key written with no value (`baseline:`) parses as nil. Keeping nil
        # would switch the feature off without a word; main failed here, so the
        # typo stays loud. An absent key never reaches parse, so it stays unset.
        # `only: false` must not become the subject name "false" either: it
        # matches nothing, so the run has no mutants and still exits 0.
        raise ConfigError, "#{origin} must be a string #{got}" if [nil, true, false].include?(value)
        # A blank cache directory (an unset CI variable) would put coverage.json
        # in the project root, so it is an error, not the default.
        raise ConfigError, "#{origin} must be a directory, not blank #{got}" if field == :cache_dir && value.to_s.strip.empty?

        value.to_s
      when :since
        # `false` is the one way to say "no scoping" in the file. It becomes nil
        # so every consumer's nil-check (runner scoping, the report's scoped
        # marker) agrees; a false left raw would skip scoping but still mark
        # the report scoped. A blank value is an error, not "no scoping": a
        # `since: "$REF"` whose variable is unset must not turn scoping off.
        return nil if value == false
        raise ConfigError, "#{origin} must be a git ref, not blank #{got}" if value.to_s.strip.empty?

        value.to_s
      end
    end

    # Reads a finite Float from a number or a plain decimal string. Rejects booleans,
    # NaN and Infinity: `Float(true)` is an error, but a YAML `.nan` is a Float.
    # A string must be digits with an optional fraction, the same digits-only rule
    # as `jobs`: `Float()` alone would also read `0x10`, `1_0`, `+2` and `1e2`.
    #
    # @api private
    # @param value [Object] raw value.
    # @return [Float, nil] the number, or nil when it is not a finite number.
    def self.finite_float(value)
      f = case value
          when Integer, Float then value.to_f
          when String then Float(value) if value.match?(/\A\d+(\.\d+)?\z/)
          end
      f if f&.finite?
    end

    # Reads an `ignore:` value into ids plus a reason for each mapping.
    # A bare string is an id with no reason. A mapping may hold `id` and
    # `reason` only. A value that is not a list, or a mapping with no id or
    # with any other key, raises {ConfigError}. The CLI maps that to exit 2.
    #
    # @api private
    # @param value [Object] the raw YAML value.
    # @param file [String, nil] config file name.
    # @return [Hash] `:ids` is an array of id strings. `:reasons` maps an id to its text.
    def self.parse_ignore_list(value, file)
      label = file || CONFIG_FILE
      case value
      when nil then return { ids: [], reasons: {} }
      when String then return { ids: [value], reasons: {} }
      when Array then items = value
      when Hash then items = [value]
      else
        raise ConfigError, "ignore in #{label} must be a list"
      end

      ids = []
      reasons = {}
      items.each_with_index do |item, index|
        number = index + 1
        case item
        when String
          ids << item unless item.empty? || ids.include?(item)
        when Hash
          id, reason = ignore_mapping(item, number, label)
          next if id.nil?

          ids << id unless ids.include?(id)
          reasons[id] = reason if reason
        else
          raise ConfigError, "ignore entry #{number} in #{label} is not an id or a mapping"
        end
      end
      { ids: ids, reasons: reasons }
    end

    # One `ignore:` mapping. Returns the id and reason.
    # Raises {ConfigError} when the entry is not usable.
    #
    # @api private
    # @param item [Hash] the mapping.
    # @param number [Integer] 1-based index in the list.
    # @param label [String] config file name.
    # @return [Array(String, String), Array(String, nil)] the id, and the reason when one was written.
    # @raise [Mutineer::ConfigError] when the mapping has no id, a non-text reason, or an unknown key.
    def self.ignore_mapping(item, number, label)
      known = %w[id reason]
      unknown = item.keys.map(&:to_s) - known
      unless unknown.empty?
        names = unknown.map(&:inspect).join(", ")
        hint = unknown.map { |key| Mutineer.did_you_mean(key, known) }.find { |text| !text.empty? }.to_s
        raise ConfigError, "ignore entry #{number} in #{label} has unknown key #{names}#{hint}"
      end

      id = item["id"] || item[:id]
      unless id.is_a?(String) && !id.strip.empty?
        raise ConfigError, "ignore entry #{number} in #{label} has no id"
      end

      reason = item.key?("reason") ? item["reason"] : item[:reason]
      if !reason.nil? && !reason.is_a?(String)
        raise ConfigError, "ignore entry #{number} in #{label} reason must be text"
      end

      text = reason.to_s.strip
      [id, text.empty? ? nil : text]
    end

    # Keep operator names the registry knows. When +strict+ is set, an unknown
    # name raises {ConfigError} (exit 2) and names the closest valid name.
    # A command-line `--operators` list replaces the file, so that call passes
    # +strict: false+ and drops unknown file names without an error.
    # Referenced lazily so config.rb carries no load-order dependency on the
    # registry; by the time a config is parsed at runtime, it is loaded.
    #
    # @api private
    # @param names [Array<String>] operator names.
    # @param file_name [String] config file name for the error.
    # @param strict [Boolean] raise on an unknown name.
    # @return [Array<String>] known operator names.
    # @raise [Mutineer::ConfigError] when +strict+ and a name is unknown.
    def self.filter_operators(names, file_name, strict:)
      known = MutatorRegistry::ALL.keys
      names.each do |n|
        next if known.include?(n)
        next unless strict

        raise ConfigError, "#{file_name}: unknown operator #{n.inspect}" \
                           "#{Mutineer.did_you_mean(n, known)} (known: #{known.join(', ')})"
      end
      names.select { |n| known.include?(n) }
    end
  end
end
