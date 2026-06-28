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

  def test_from_file_warns_on_unknown_operator_and_drops_it
    with_config("operators: [arithmetic, bogus]\n") do |path|
      _, err = capture_io { @hash = Config.from_file(path) }
      assert_includes err, "unknown operator"
      assert_equal ["arithmetic"], @hash[:operators]
    end
  end

  # Boot mode keys are accepted (not warned/ignored) and resolve onto the Config.
  def test_from_file_accepts_boot_and_rails
    with_config("boot: config/environment\nrails: true\n") do |path|
      out, err = capture_io { @hash = Config.from_file(path) }
      assert_empty out
      assert_empty err
      assert_equal({ boot: "config/environment", rails: true }, @hash)

      cfg = Config.resolve({}, @hash, Set.new)
      assert_equal "config/environment", cfg.boot
      assert_equal true, cfg.rails
      assert_equal "redefine", cfg.strategy # --rails sugar, no explicit --strategy
    end
  end

  # R8: the lib layer raises a typed error rather than calling exit (which would
  # kill an embedding host). The CLI maps it to exit 2.
  def test_from_file_malformed_yaml_raises_config_error
    with_config("operators: [\n") do |path|
      assert_raises(Mutineer::ConfigError) { Config.from_file(path) }
    end
  end

  # --- resolve precedence (KTD3) ---

  def test_resolve_cli_wins_over_file
    explicit = Set.new(%i[operators])
    cfg = Config.resolve({ operators: ["comparison"] }, { operators: ["arithmetic"], jobs: 8 }, explicit)
    assert_equal ["comparison"], cfg.operators # CLI typed
    assert_equal 8, cfg.jobs                    # filled from file
  end

  def test_resolve_file_fills_gaps
    cfg = Config.resolve({}, { operators: ["arithmetic"], threshold: 70.0 }, Set.new)
    assert_equal ["arithmetic"], cfg.operators
    assert_equal 70.0, cfg.threshold
  end

  def test_resolve_defaults_when_neither
    cfg = Config.resolve({}, {}, Set.new)
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
