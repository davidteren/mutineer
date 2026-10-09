# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

# `mutineer init` writes a starter config and prints the first run command.
class InitTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "mutineer")

  def mutineer(*args, chdir:)
    Open3.capture3(RbConfig.ruby, "-I#{File.join(ROOT, "lib")}", BIN, *args, chdir: chdir)
  end

  def test_empty_folder_writes_a_config_that_loads_and_prints_lib
    Dir.mktmpdir("mutineer-init") do |dir|
      out, err, status = mutineer("init", chdir: dir)
      assert_equal 0, status.exitstatus, err
      assert_empty err
      assert_equal "mutineer run lib\n", out

      path = File.join(dir, ".mutineer.yml")
      text = File.read(path)
      assert_includes text, "# since: origin/main"
      refute_includes text, "rails:"
      refute_includes text, "daemon:"
      _stdout, warn = capture_io { @hash = Mutineer::Config.from_file(path) }
      assert_empty warn
      assert_equal Mutineer::MutatorRegistry::DEFAULT_NAMES, @hash[:operators]
      refute @hash.key?(:since)
      refute @hash.key?(:rails)
    end
  end

  def test_rails_with_services_sets_rails_and_prints_those_folders
    Dir.mktmpdir("mutineer-init-rails") do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "services"))
      FileUtils.mkdir_p(File.join(dir, "lib"))
      out, err, status = mutineer("init", "--rails", chdir: dir)
      assert_equal 0, status.exitstatus, err
      assert_empty err
      assert_equal "mutineer run app/models app/services lib\n", out

      path = File.join(dir, ".mutineer.yml")
      text = File.read(path)
      assert_includes text, "rails: true"
      assert_includes text, "# daemon: true"
      assert_includes text, "https://davidteren.github.io/mutineer/rails.html#daemon"
      _stdout, warn = capture_io { @hash = Mutineer::Config.from_file(path) }
      assert_empty warn
      assert_equal true, @hash[:rails]
      refute @hash.key?(:daemon)
      refute @hash.key?(:since)
    end
  end

  def test_rails_without_services_omits_that_folder
    Dir.mktmpdir("mutineer-init-rails") do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "lib"))
      out, err, status = mutineer("init", "--rails", chdir: dir)
      assert_equal 0, status.exitstatus, err
      assert_empty err
      assert_equal "mutineer run app/models lib\n", out
      refute_includes out, "app/services"
    end
  end

  # A Rails app often has no lib folder. The printed command must name only
  # folders that exist, or the first run exits before any mutant runs.
  def test_rails_without_lib_omits_that_folder
    Dir.mktmpdir("mutineer-init-rails") do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      out, err, status = mutineer("init", "--rails", chdir: dir)
      assert_equal 0, status.exitstatus, err
      assert_empty err
      assert_equal "mutineer run app/models\n", out
      refute_includes out, "lib"
    end
  end

  def test_rails_with_no_source_folder_writes_config_and_prints_no_run
    Dir.mktmpdir("mutineer-init-rails") do |dir|
      out, err, status = mutineer("init", "--rails", chdir: dir)
      assert_equal 0, status.exitstatus
      refute_includes out, "mutineer run"
      assert_includes err, "no source folder found"
      assert File.file?(File.join(dir, ".mutineer.yml"))
    end
  end

  # The project directory is not created. A missing parent is a usage error.
  def test_missing_directory_exits_with_a_message
    Dir.mktmpdir("mutineer-init-missing") do |root|
      missing = File.join(root, "gone")
      out, err = capture_io do
        @status = Mutineer::Init.run([], dir: missing)
      end
      assert_equal 2, @status
      assert_includes err, "no such directory"
      assert_empty out
      refute File.exist?(File.join(missing, ".mutineer.yml"))
    end
  end

  def test_existing_file_is_kept_unless_force
    Dir.mktmpdir("mutineer-init-keep") do |dir|
      path = File.join(dir, ".mutineer.yml")
      File.write(path, "threshold: 10\n")
      out, err, status = mutineer("init", chdir: dir)
      assert_equal 2, status.exitstatus
      assert_includes err, "already exists"
      assert_includes err, "--force"
      assert_empty out
      assert_equal "threshold: 10\n", File.read(path)

      out, err, status = mutineer("init", "--force", chdir: dir)
      assert_equal 0, status.exitstatus, err
      assert_equal "mutineer run lib\n", out
      refute_equal "threshold: 10\n", File.read(path)
      assert_includes File.read(path), "operators:"
    end
  end

  # A directory named .mutineer.yml is not a config file. --force cannot replace it.
  def test_a_directory_named_config_is_refused
    Dir.mktmpdir("mutineer-init-dir") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".mutineer.yml"))
      _out, err, status = mutineer("init", "--force", chdir: dir)
      assert_equal 2, status.exitstatus
      assert_includes err, "is a directory"
      assert File.directory?(File.join(dir, ".mutineer.yml"))
    end
  end
end
