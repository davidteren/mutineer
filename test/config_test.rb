# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ConfigTest < Minitest::Test
  Config = Mutineer::Config

  # --- find_file (KTD4) ---

  def test_find_file_walks_up_to_two_dirs
    Dir.mktmpdir do |root|
      deep = File.join(root, "a", "b", "c")
      FileUtils.mkdir_p(deep)
      cfg = File.join(root, "a", ".mutineer.yml")
      File.write(cfg, "jobs: 2\n")
      # home is unrelated so the walk does not stop early
      assert_equal cfg, Config.find_file(deep, File.join(root, "nowhere"))
    end
  end

  def test_find_file_returns_nil_when_absent
    Dir.mktmpdir do |root|
      assert_nil Config.find_file(root, File.join(root, "nowhere"))
    end
  end

  def test_find_file_stops_after_home
    Dir.mktmpdir do |root|
      home = File.join(root, "home")
      child = File.join(home, "proj")
      FileUtils.mkdir_p(child)
      File.write(File.join(root, ".mutineer.yml"), "jobs: 9\n") # above home -> not seen
      assert_nil Config.find_file(child, home)
    end
  end

  # --- from_file (R7/R7a) ---

  def test_from_file_symbolizes_known_keys
    with_config("operators: [arithmetic]\njobs: 4\nthreshold: 80\nrequire: [a.rb, b.rb]\n") do |path|
      out, = capture_io { @hash = Config.from_file(path) }
      assert_empty out
      assert_equal({ operators: ["arithmetic"], jobs: 4, threshold: 80.0,
                     require_paths: ["a.rb", "b.rb"] }, @hash)
    end
  end

  def test_from_file_warns_on_unknown_key_and_drops_it
    with_config("operatros: [arithmetic]\n") do |path| # typo
      _, err = capture_io { @hash = Config.from_file(path) }
      assert_includes err, "unknown config key"
      assert_empty @hash
    end
  end

  def test_from_file_rejects_non_numeric_threshold
    with_config("threshold: abc\n") do |path|
      err = assert_raises(Mutineer::ConfigError) { Config.from_file(path) }
      assert_match(/\.mutineer\.yml: threshold must be a number/, err.message)
    end
  end

  # --- Config.parse: one strict parse at the boundary (#105) ---

  def parse_error(field, value, file: nil)
    assert_raises(Mutineer::ConfigError) { Config.parse(field, value, file: file) }.message
  end

  def test_parse_positive_int_accepts_integers_and_integer_strings
    assert_equal 4, Config.parse(:jobs, 4)
    assert_equal 4, Config.parse(:jobs, "4")
  end

  def test_parse_timeouts_take_whole_seconds
    assert_equal 300, Config.parse(:timeout, "300")
    assert_equal 600, Config.parse(:capture_timeout, 600, file: ".mutineer.yml")
    assert_match(/\A--timeout must be a positive integer/, parse_error(:timeout, "0"))
    assert_match(/\A\.mutineer\.yml: capture_timeout must be a positive integer/,
                 parse_error(:capture_timeout, 1.5, file: ".mutineer.yml"))
  end

  def test_parse_positive_int_rejects_everything_else_naming_the_origin
    ["1.9", 1.9, true, 0, "0", -1, "abc", "", nil, "1e3"].each do |bad|
      assert_match(/\A--jobs must be a positive integer, digits only \(got: /, parse_error(:jobs, bad), bad.inspect)
      assert_match(/\A\.mutineer\.yml: jobs must be a positive integer, digits only/, parse_error(:jobs, bad, file: ".mutineer.yml"))
    end
  end

  def test_parse_percent_bounds
    assert_equal 0.0, Config.parse(:threshold, "0")
    assert_equal 100.0, Config.parse(:threshold, 100)
    ["101", -1, "abc", true, Float::NAN, Float::INFINITY, "NaN"].each do |bad|
      assert_match(/\A--threshold must be a number between 0 and 100/, parse_error(:threshold, bad), bad.inspect)
    end
  end

  def test_parse_nonneg_float_rejects_negative_and_non_finite
    assert_equal 0.0, Config.parse(:baseline_epsilon, "0")
    assert_equal 0.5, Config.parse(:baseline_epsilon, "0.5")
    ["abc", "-1", -0.1, Float::NAN, Float::INFINITY, "Infinity", true, nil].each do |bad|
      assert_match(/\A--baseline-epsilon must be a finite number, 0 or greater/,
                   parse_error(:baseline_epsilon, bad), bad.inspect)
    end
  end

  # A string takes the same digits-only rule as `jobs`. `Float()` alone read
  # "0x10" as 16.0, "1_0" as 10.0, "+2" as 2.0 and "1e2" as 100.0.
  def test_parse_float_strings_take_plain_decimals_only
    %i[threshold baseline_epsilon].each do |field|
      assert_equal 2.0, Config.parse(field, "2")
      assert_equal 2.5, Config.parse(field, "2.5")
      ["0x10", "1_0", "+2", "1e2", ".5", "5.", " 2"].each do |bad|
        assert_match(/\A--#{field.to_s.tr('_', '-')} must be a /, parse_error(field, bad), "#{field} #{bad.inspect}")
      end
    end
  end

  def test_parse_float_still_accepts_yaml_numbers
    assert_equal 5.0, Config.parse(:threshold, 5)
    assert_equal 62.5, Config.parse(:threshold, 62.5)
    assert_equal 0.25, Config.parse(:baseline_epsilon, 0.25)
    assert_equal 1.0, Config.parse(:baseline_epsilon, 1)
  end

  def test_parse_bool_accepts_only_true_and_false
    assert_equal true, Config.parse(:rails, true)
    assert_equal false, Config.parse(:rails, "false")
    assert_equal true, Config.parse(:rails, "true")
    ["yes", "1", 1, nil, "TRUE"].each do |bad|
      assert_match(/\.mutineer\.yml: rails must be true or false/, parse_error(:rails, bad, file: ".mutineer.yml"))
    end
  end

  def test_parse_enum_normalizes_strategy_aliases_and_rejects_unknown_values
    assert_equal "reload", Config.parse(:strategy, "7a")
    assert_equal "redefine", Config.parse(:strategy, "7b")
    assert_equal "json", Config.parse(:format, "json")
    assert_includes parse_error(:format, "csv"), %(unknown format "csv". Expected: human, json, html)
    assert_includes parse_error(:framework, "junit", file: ".mutineer.yml"),
                    %(.mutineer.yml: unknown framework "junit")
  end

  def test_parse_since_maps_false_to_nil_and_keeps_a_ref
    assert_nil Config.parse(:since, false)
    assert_equal "main", Config.parse(:since, "main")
  end

  # A blank ref is an error on every path: a shell variable that expands to
  # nothing must not silently turn diff scoping off.
  def test_parse_since_rejects_a_blank_value_naming_the_origin
    [nil, "", "  ", "\t"].each do |bad|
      assert_equal "--since must be a git ref, not blank (got: #{bad.inspect})", parse_error(:since, bad)
      assert_equal ".mutineer.yml: since must be a git ref, not blank (got: #{bad.inspect})",
                   parse_error(:since, bad, file: ".mutineer.yml")
    end
  end

  def test_parse_string_converts_numbers
    assert_equal "5", Config.parse(:only, 5)
  end

  # A key with no value is nil in YAML. Keeping nil would turn `baseline:` off
  # without a word, so it is an error; a key that is absent is simply not set.
  def test_from_file_rejects_a_string_key_with_no_value
    %w[only boot baseline test_command].each do |key|
      with_config("#{key}:\n") do |path|
        err = assert_raises(Mutineer::ConfigError, key) { Config.from_file(path) }
        assert_equal ".mutineer.yml: #{key} must be a string (got: nil)", err.message
      end
    end
  end

  def test_from_file_leaves_an_absent_string_key_unset
    with_config("jobs: 2\n") do |path|
      assert_equal({ jobs: 2 }, Config.from_file(path))
    end
  end

  # A boolean is not a string: `only: false` once became the subject name "false",
  # so the run had no mutants and still exited 0.
  def test_parse_string_rejects_booleans_naming_the_origin
    [true, false].each do |bad|
      assert_equal "--only must be a string (got: #{bad})", parse_error(:only, bad)
      assert_equal ".mutineer.yml: only must be a string (got: #{bad})",
                   parse_error(:only, bad, file: ".mutineer.yml")
    end
  end

  def test_from_file_rejects_a_boolean_for_a_string_key
    with_config("only: false\n") do |path|
      err = assert_raises(Mutineer::ConfigError) { Config.from_file(path) }
      assert_match(/\.mutineer\.yml: only must be a string \(got: false\)/, err.message)
    end
  end

  def test_from_file_rejects_bad_jobs_and_bad_booleans
    with_config("jobs: 1.9\n") do |path|
      err = assert_raises(Mutineer::ConfigError) { Config.from_file(path) }
      assert_match(/\.mutineer\.yml: jobs must be a positive integer, digits only \(got: 1\.9\)/, err.message)
    end
    with_config("jobs: true\n") do |path|
      assert_raises(Mutineer::ConfigError) { Config.from_file(path) }
    end
    with_config("rails: \"yes\"\n") do |path|
      assert_raises(Mutineer::ConfigError) { Config.from_file(path) }
    end
  end

  def test_matrix_is_a_boolean_config_key_off_by_default
    refute Config.new.matrix
    with_config("matrix: true\n") do |path|
      assert_equal({ matrix: true }, Config.from_file(path))
    end
    with_config("matrix: \"yes\"\n") do |path|
      err = assert_raises(Mutineer::ConfigError) { Config.from_file(path) }
      assert_match(/\.mutineer\.yml: matrix must be true or false/, err.message)
    end
  end

  def test_origin_names_the_file_key_or_the_flag
    cfg = Config.resolve({ fail_fast: true }, { matrix: true, fail_fast: false })
    assert_equal "matrix in .mutineer.yml", cfg.origin(:matrix)
    assert_equal "--fail-fast", cfg.origin(:fail_fast)
    assert_equal "--daemon", cfg.origin(:daemon)
  end

  def test_known_keys_come_from_the_schema
    assert_equal Mutineer::CONFIG_OPTIONS.filter_map(&:yaml_key), Mutineer::KNOWN_KEYS
  end

  def test_from_file_warns_on_unknown_operator_and_drops_it
    with_config("operators: [arithmetic, bogus]\n") do |path|
      _, err = capture_io { @hash = Config.from_file(path) }
      assert_includes err, "unknown operator"
      assert_equal ["arithmetic"], @hash[:operators]
    end
  end

  # A blank operator list is not "use the defaults". `operators:` became []
  # and the run exited 0 with no mutants. An empty require or ignore matches
  # the default, so those stay valid.
  def test_from_file_rejects_a_blank_operators_key
    ["operators:\n", "operators: ~\n", "operators: []\n", "operators: \"\"\n"].each do |yaml|
      with_config(yaml) do |path|
        err = assert_raises(Mutineer::ConfigError, yaml) { Config.from_file(path) }
        assert_match(/\.mutineer\.yml: operators must name at least one operator, not blank \(got: /, err.message)
      end
    end
  end

  def test_from_file_keeps_an_empty_require_or_ignore
    with_config("require: []\nignore:\n") do |path|
      assert_equal({ require_paths: [], ignore: [] }, Config.from_file(path))
    end
  end

  def test_parse_string_list_rejects_a_blank_operator_list
    [nil, true, false, [], ""].each do |bad|
      assert_equal "--operators must name at least one operator, not blank (got: #{bad.inspect})",
                   parse_error(:operators, bad)
    end
    assert_equal ["arithmetic"], Config.parse(:operators, ["arithmetic"])
    assert_equal [], Config.parse(:ignore, nil)
    assert_equal [], Config.parse(:require_paths, [])
    assert_equal ["a.rb"], Config.parse(:require_paths, "a.rb")
  end

  # Every name unknown: the warning still names the typo, then the file is
  # an error so the empty list cannot exit 0.
  def test_from_file_rejects_operators_that_are_all_unknown
    with_config("operators: [bogus]\n") do |path|
      err = nil
      _, stderr = capture_io do
        err = assert_raises(Mutineer::ConfigError) { Config.from_file(path) }
      end
      assert_includes stderr, "unknown operator"
      assert_equal ".mutineer.yml: operators must name at least one known operator", err.message
    end
  end

  # --operators replaces the file list. A blank or unknown file list must not
  # raise before that replacement. Called alone, the file still raises.
  def test_from_file_defers_a_blank_or_unknown_list_for_the_cli
    with_config("operators: []\n") do |path|
      hash = Config.from_file(path, defer_operators: true)
      cfg = Config.resolve({ operators: ["arithmetic"] }, hash)
      assert_equal ["arithmetic"], cfg.operators
    end
    with_config("operators: [bogus]\n") do |path|
      hash = nil
      _, stderr = capture_io { hash = Config.from_file(path, defer_operators: true) }
      assert_includes stderr, "unknown operator"
      cfg = Config.resolve({ operators: ["arithmetic"] }, hash)
      assert_equal ["arithmetic"], cfg.operators
    end
  end

  # Boot mode keys are accepted (not warned/ignored) and resolve onto the Config.
  def test_from_file_accepts_boot_and_rails
    with_config("boot: config/environment\nrails: true\n") do |path|
      out, err = capture_io { @hash = Config.from_file(path) }
      assert_empty out
      assert_empty err
      assert_equal({ boot: "config/environment", rails: true }, @hash)

      cfg = Config.resolve({}, @hash)
      assert_equal "config/environment", cfg.boot
      assert_equal true, cfg.rails
      assert_equal "redefine", cfg.strategy # --rails sugar, no explicit --strategy
    end
  end

  # --since is accepted from the config file and resolves onto the Config.
  def test_from_file_accepts_since
    with_config("since: origin/main\n") do |path|
      out, err = capture_io { @hash = Config.from_file(path) }
      assert_empty out
      assert_empty err
      assert_equal({ since: "origin/main" }, @hash)

      cfg = Config.resolve({}, @hash)
      assert_equal "origin/main", cfg.since
    end
  end

  # #10: an ignore: list of stable mutant ids is parsed (not warned/ignored) and
  # coerced to strings, resolving onto the Config.
  def test_from_file_accepts_ignore_list
    with_config("ignore:\n  - a1b2c3d4e5f6\n  - 0011223344ff\n") do |path|
      out, err = capture_io { @hash = Config.from_file(path) }
      assert_empty out
      assert_empty err
      assert_equal({ ignore: %w[a1b2c3d4e5f6 0011223344ff] }, @hash)
      assert_equal %w[a1b2c3d4e5f6 0011223344ff], Config.resolve({}, @hash).ignore
    end
  end

  def test_ignore_defaults_to_empty_array
    assert_equal [], Config.new.ignore
    assert_equal [], Config.resolve({}, {}).ignore
  end

  # #27: test_command is accepted from the config file (snake_case key) and
  # resolves onto the Config; an explicit CLI value wins over the file.
  def test_from_file_accepts_test_command
    with_config("test_command: bundle exec rails test %{files}\n") do |path|
      out, err = capture_io { @hash = Config.from_file(path) }
      assert_empty out
      assert_empty err
      assert_equal({ test_command: "bundle exec rails test %{files}" }, @hash)
      assert_equal "bundle exec rails test %{files}", Config.resolve({}, @hash).test_command
    end
  end

  def test_cli_test_command_overrides_file
    with_config("test_command: from_file %{files}\n") do |path|
      capture_io { @hash = Config.from_file(path) }
      cfg = Config.resolve({ test_command: "from_cli %{files}" }, @hash)
      assert_equal "from_cli %{files}", cfg.test_command
    end
  end

  # --no-since marks :since explicit with a nil value, so a .mutineer.yml
  # `since:` key must NOT refill it (a typed no beats the file).
  def test_no_since_beats_file_since
    with_config("since: origin/main\n") do |path|
      capture_io { @hash = Config.from_file(path) }
      assert_nil Config.resolve({ since: nil }, @hash).since
      assert_equal "origin/main", Config.resolve({}, @hash).since, "without the flag the file still wins"
    end
  end

  # `since: false` normalizes to nil: a raw false would skip scoping in the
  # runner but still mark the JSON report scoped, silently disabling the
  # baseline score-drop gate on a full run.
  def test_since_false_normalizes_to_nil
    with_config("since: false\n") do |path|
      capture_io { @hash = Config.from_file(path) }
      assert_nil Config.resolve({}, @hash).since
    end
  end

  def test_from_file_rejects_a_blank_since
    ["since: \"\"\n", "since:\n", "since: \"  \"\n"].each do |yaml|
      with_config(yaml) do |path|
        err = assert_raises(Mutineer::ConfigError, yaml) { Config.from_file(path) }
        assert_match(/\A\.mutineer\.yml: since must be a git ref, not blank/, err.message)
      end
    end
  end

  # --- framework: explicit value, config file, and auto-detect ---

  def test_from_file_accepts_framework
    with_config("framework: rspec\n") do |path|
      out, err = capture_io { @hash = Config.from_file(path) }
      assert_empty out
      assert_empty err
      assert_equal({ framework: "rspec" }, @hash)
      cfg = Config.resolve({}, @hash)
      assert_equal "rspec", cfg.framework
    end
  end

  # #8: --verbose is a plain boolean field, parsed from YAML and defaulting false.
  def test_from_file_accepts_verbose
    with_config("verbose: true\n") do |path|
      out, err = capture_io { @hash = Config.from_file(path) }
      assert_empty out
      assert_empty err
      assert_equal({ verbose: true }, @hash)
      assert_equal true, Config.resolve({}, @hash).verbose
    end
  end

  def test_verbose_defaults_to_false
    assert_equal false, Config.new.verbose
    assert_equal false, Config.resolve({}, {}).verbose
  end

  def test_resolve_verbose_from_cli
    assert_equal true, Config.resolve({ verbose: true }, {}).verbose
  end

  # In-process --rails shares one DB; always serial. --daemon may use --jobs N.
  def test_resolve_rails_defaults_jobs_to_one
    assert_equal 1, Config.resolve({ rails: true }, {}).jobs
  end

  def test_resolve_rails_forces_serial_even_when_jobs_explicit
    cfg = Config.resolve({ rails: true, jobs: 4 }, {})
    assert_equal 1, cfg.jobs
  end

  def test_resolve_rails_daemon_keeps_explicit_jobs
    cfg = Config.resolve({ rails: true, daemon: true, jobs: 4 }, {})
    assert_equal 4, cfg.jobs
  end

  def test_resolve_auto_detects_rspec_from_spec_test_names
    cfg = Config.resolve({ tests: ["foo_spec.rb", "bar_spec.rb"] }, {})
    assert_equal "rspec", cfg.framework
  end

  def test_resolve_defaults_minitest_for_test_names
    cfg = Config.resolve({ tests: ["foo_test.rb", "bar_test.rb"] }, {})
    assert_equal "minitest", cfg.framework
  end

  def test_resolve_defaults_minitest_when_ambiguous_or_empty
    assert_equal "minitest", Config.resolve({}, {}).framework
    # tie (1 spec, 1 test) is not a majority -> minitest
    assert_equal "minitest", Config.resolve({ tests: ["a_spec.rb", "b_test.rb"] }, {}).framework
  end

  def test_explicit_framework_wins_over_autodetect
    cfg = Config.resolve({ framework: "minitest", tests: ["a_spec.rb", "b_spec.rb"] }, {})
    assert_equal "minitest", cfg.framework
  end

  # R8: the lib layer raises a typed error rather than calling exit (which would
  # kill an embedding host). The CLI maps it to exit 2.
  def test_from_file_malformed_yaml_raises_config_error
    with_config("operators: [\n") do |path|
      assert_raises(Mutineer::ConfigError) { Config.from_file(path) }
    end
  end

  # --- provenance is derived from the layers, not tracked by hand (#103) ---

  def test_explicit_reports_keys_from_either_layer_including_false_and_nil
    cfg = Config.resolve({ since: nil }, { rails: false, jobs: 2 })
    %i[since rails jobs].each { |k| assert cfg.explicit?(k), k }
    refute cfg.explicit?(:framework)
    refute cfg.explicit?(:strategy)
  end

  def test_programmatic_config_new_has_no_explicit_keys
    refute Config.new(jobs: 2).explicit?(:jobs)
  end

  def test_rails_sugar_keeps_a_strategy_the_file_wrote
    cfg = Config.resolve({ rails: true }, { strategy: "reload" })
    assert_equal "reload", cfg.strategy
  end

  def test_rails_sugar_redefines_strategy_when_nobody_wrote_one
    assert_equal "redefine", Config.resolve({ rails: true }, {}).strategy
  end

  # Every option that has a YAML key: a value typed on the command line beats
  # the file's value. A new option without a row here fails the coverage check,
  # so a forgotten precedence rule shows up as a red test instead of a bug report.
  LAYER_SAMPLES = {
    operators: [%w[arithmetic], %w[comparison]],
    jobs: [3, 5],
    threshold: [70.0, 80.0],
    only: ["a", "b"],
    require_paths: [%w[a.rb], %w[b.rb]],
    boot: ["a", "b"],
    rails: [false, true],
    since: ["main", nil],
    framework: %w[minitest rspec],
    verbose: [false, true],
    ignore: [%w[aaaaaaaaaaaa], %w[bbbbbbbbbbbb]],
    baseline: ["a.json", "b.json"],
    fail_fast: [false, true],
    matrix: [false, true],
    test_command: ["a %{files}", "b %{files}"],
    daemon: [false, true],
    timeout: [30, 60],
    capture_timeout: [300, 600]
  }.freeze

  def test_every_option_with_a_yaml_key_has_a_layer_sample
    fields = Mutineer::CONFIG_OPTIONS.select(&:yaml_key).map(&:field)
    assert_equal fields.sort, LAYER_SAMPLES.keys.sort
  end

  def test_cli_value_beats_file_value_for_every_yaml_option
    LAYER_SAMPLES.each do |field, (file_value, cli_value)|
      cfg = Config.resolve({ field => cli_value }, { field => file_value })
      got = cfg.public_send(field)
      if cli_value.nil?
        assert_nil got, "CLI nil lost for #{field}"
      else
        assert_equal cli_value, got, "CLI value lost for #{field}"
      end
      assert cfg.explicit?(field), "#{field} not reported as explicit"
    end
  end

  def test_file_value_applies_when_the_cli_is_silent_for_every_yaml_option
    LAYER_SAMPLES.each do |field, (file_value, _)|
      cfg = Config.resolve({}, { field => file_value })
      assert_equal file_value, cfg.public_send(field), "file value lost for #{field}"
      assert cfg.explicit?(field), "#{field} not reported as explicit"
    end
  end

  # --- resolve precedence (KTD3) ---

  def test_resolve_cli_wins_over_file
    cfg = Config.resolve({ operators: ["comparison"] }, { operators: ["arithmetic"], jobs: 8 })
    assert_equal ["comparison"], cfg.operators # CLI typed
    assert_equal 8, cfg.jobs                    # filled from file
  end

  def test_resolve_file_fills_gaps
    cfg = Config.resolve({}, { operators: ["arithmetic"], threshold: 70.0 })
    assert_equal ["arithmetic"], cfg.operators
    assert_equal 70.0, cfg.threshold
  end

  def test_resolve_defaults_when_neither
    cfg = Config.resolve({}, {})
    assert_nil cfg.operators            # nil => Runner uses DEFAULT_NAMES
    assert_equal "reload", cfg.strategy
    assert_equal "human", cfg.format
    assert_operator cfg.jobs, :>=, 1    # Etc.nprocessors
  end

  private

  def with_config(yaml)
    Dir.mktmpdir do |root|
      path = File.join(root, ".mutineer.yml")
      File.write(path, yaml)
      yield path
    end
  end
end
