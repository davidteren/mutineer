# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/mock"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require_relative "test_helper"
require "mutineer/daemon_client"

# #100: Open3 keeps a key the spawn hash omits. These tests spawn a real child
# with the daemon's environment and +unsetenv_others+, the same flag as
# DaemonClient#spawn_daemon. A check that the hash lacks a key would still
# pass while the child inherited the tool setting.
class DaemonClientEnvTest < Minitest::Test
  RUBY = RbConfig.ruby
  UNSET = Mutineer::DaemonClient::BUNDLER_UNSET

  def test_spawn_drops_tool_injection_and_keeps_app_settings
    Dir.mktmpdir("daemon-env") do |root|
      injected = write_parent_require(root)
      chruby_bin = File.expand_path("~/.rubies/app-ruby/bin")
      app_home = "/usr/local/bundle"
      home = File.join(root, "home")
      version_bin = File.join(home, ".rbenv", "versions", "9.9.9", "bin")
      FileUtils.mkdir_p(File.join(home, ".rbenv", "shims"))
      updates = tool_over_app_env(root, injected, version_bin, chruby_bin, app_home)
      updates["HOME"] = home
      updates["RBENV_ROOT"] = nil
      with_env(updates) do
        observed = observe(client_for(root), root)

        assert_nil observed["MUTINEER_PARENT_CODE_LOADED"]
        assert_nil observed["RUBYOPT"]
        assert_nil observed["RUBYLIB"]
        assert_nil observed["BUNDLER_SETUP"]
        assert_equal app_home, observed["GEM_HOME"]
        assert_equal "app_required_group", observed["BUNDLE_WITHOUT"]
        assert_equal app_home, observed["BUNDLE_APP_CONFIG"]
        assert_equal File.join(root, "Gemfile"), observed["BUNDLE_GEMFILE"]
        assert_equal "kept", observed["MUTINEER_APP_PROBE"]
        assert_equal "3.3.6", observed["RBENV_VERSION"]
        assert_equal "3.2.1", observed["ASDF_RUBY_VERSION"]
        parts = observed["PATH"].split(File::PATH_SEPARATOR)
        refute_includes parts, version_bin
        refute_includes parts, "#{version_bin}/"
        assert_includes parts, chruby_bin
        assert_includes parts, File.join(home, ".rbenv", "shims")
      end
    end
  end

  def test_spawn_applies_explicit_ruby_pin_and_rails_test_env
    Dir.mktmpdir("daemon-env") do |root|
      gemfile = File.join(root, "app.gemfile")
      with_env(
        "RBENV_VERSION" => "3.4.9",
        "RAILS_ENV" => nil,
        "BUNDLER_ORIG_RUBYOPT" => UNSET,
        "RUBYOPT" => "-rbundler/setup"
      ) do
        client = Mutineer::DaemonClient.new(
          boot: { rails: true }, app_root: root, ruby_version: "3.3.6", gemfile: gemfile
        )
        observed = observe(client, root)

        assert_equal "3.3.6", observed["RBENV_VERSION"]
        assert_equal gemfile, observed["BUNDLE_GEMFILE"]
        assert_equal "test", observed["RAILS_ENV"]
        assert_equal "1", observed["PARALLEL_WORKERS"]
        assert_nil observed["RUBYOPT"]
      end
    end
  end

  # The flag and the cleaned env have to be on the real spawn call. A helper
  # that adds them only in the test would stay green if spawn_daemon dropped them.
  def test_spawn_daemon_passes_unsetenv_others
    root = Dir.mktmpdir("daemon-env")
    seen = {}
    seen_env = nil
    client = client_for(root)
    Open3.stub(:popen3, lambda { |*args, **kwargs|
      seen_env = args[0]
      seen.replace(kwargs)
      raise Errno::ENOENT
    }) do
      error = assert_raises(Mutineer::DaemonBootError) { client.send(:spawn_daemon) }
      assert_match(/ENOENT/, error.message)
    end
    assert_equal true, seen[:unsetenv_others]
    assert_equal root, seen[:chdir]
    assert_equal client.send(:app_env), seen_env
  ensure
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  def test_spawn_keeps_version_bin_when_no_shim_exists
    Dir.mktmpdir("daemon-env") do |root|
      version_bin = File.join(root, ".rbenv", "versions", "9.9.9", "bin")
      path = [version_bin, "/usr/bin"].join(File::PATH_SEPARATOR)
      with_env("HOME" => root, "RBENV_ROOT" => nil, "PATH" => path, "BUNDLER_ORIG_PATH" => path) do
        observed = observe(client_for(root), root)
        assert_includes observed["PATH"].split(File::PATH_SEPARATOR), version_bin
      end
    end
  end

  def test_spawn_replaces_parallel_workers
    Dir.mktmpdir("daemon-env") do |root|
      with_env("PARALLEL_WORKERS" => "8") do
        observed = observe(client_for(root), root)
        assert_equal "1", observed["PARALLEL_WORKERS"]
      end
    end
  end

  def test_spawn_keeps_existing_rails_env
    Dir.mktmpdir("daemon-env") do |root|
      with_env("RAILS_ENV" => "production", "BUNDLER_ORIG_RUBYOPT" => UNSET) do
        observed = observe(client_for(root, boot: { "rails" => true }), root)
        assert_equal "production", observed["RAILS_ENV"]
      end
    end
  end

  # A bare BUNDLE_WITHOUT belongs to the tool. A saved BUNDLE_PATH is the app's.
  # A saved RUBYOPT is still the tool's require list, so it stays out.
  def test_spawn_drops_unsaved_bundle_settings_and_a_saved_rubyopt
    Dir.mktmpdir("daemon-env") do |root|
      with_env(
        "BUNDLE_WITHOUT" => "tool_group",
        "BUNDLE_PATH" => "/tmp/tool-bundle",
        "BUNDLER_ORIG_BUNDLE_PATH" => "/app/bundle",
        "RUBYOPT" => "-rother",
        "BUNDLER_ORIG_RUBYOPT" => "-rtool_saved"
      ) do
        observed = observe(client_for(root), root)
        assert_nil observed["BUNDLE_WITHOUT"]
        assert_equal "/app/bundle", observed["BUNDLE_PATH"]
        assert_nil observed["RUBYOPT"]
      end
    end
  end

  # An unsaved gem path or Bundler version belongs to the tool. A saved value
  # is the app's and stays.
  def test_spawn_drops_an_unsaved_gem_path_and_bundler_version
    Dir.mktmpdir("daemon-env") do |root|
      with_env(
        "GEM_PATH" => "/tmp/tool-gems",
        "BUNDLER_ORIG_GEM_PATH" => nil,
        "BUNDLER_VERSION" => "2.6.9",
        "BUNDLER_ORIG_BUNDLER_VERSION" => nil
      ) do
        observed = observe(client_for(root), root)
        assert_nil observed["GEM_PATH"]
        assert_nil observed["BUNDLER_VERSION"]
      end

      with_env(
        "GEM_PATH" => "/tmp/tool-gems",
        "BUNDLER_ORIG_GEM_PATH" => "/app/gems",
        "BUNDLER_VERSION" => "2.6.9",
        "BUNDLER_ORIG_BUNDLER_VERSION" => "2.4.1"
      ) do
        observed = observe(client_for(root), root)
        assert_equal "/app/gems", observed["GEM_PATH"]
        assert_equal "2.4.1", observed["BUNDLER_VERSION"]
      end
    end
  end

  def test_spawn_keeps_an_asdf_bin_when_only_rbenv_shims_exist
    Dir.mktmpdir("daemon-env") do |root|
      home = File.join(root, "home")
      FileUtils.mkdir_p(File.join(home, ".rbenv", "shims"))
      asdf_bin = File.join(root, ".asdf", "installs", "ruby", "3.3.0", "bin")
      rbenv_bin = File.join(home, ".rbenv", "versions", "3.3.0", "bin")
      path = [asdf_bin, rbenv_bin, "/usr/bin"].join(File::PATH_SEPARATOR)
      with_env("HOME" => home, "RBENV_ROOT" => nil, "PATH" => path, "BUNDLER_ORIG_PATH" => path, "ASDF_DATA_DIR" => nil) do
        parts = observe(client_for(root), root)["PATH"].split(File::PATH_SEPARATOR)
        assert_includes parts, asdf_bin
        refute_includes parts, rbenv_bin
        assert_equal File.join(home, ".rbenv", "shims"), parts.first
      end
    end
  end

  def test_spawn_keeps_an_rbenv_bin_when_only_asdf_shims_exist
    Dir.mktmpdir("daemon-env") do |root|
      home = File.join(root, "home")
      FileUtils.mkdir_p(File.join(home, ".asdf", "shims"))
      asdf_bin = File.join(home, ".asdf", "installs", "ruby", "3.3.0", "bin")
      rbenv_bin = File.join(home, ".rbenv", "versions", "3.3.0", "bin")
      path = [rbenv_bin, asdf_bin, "/usr/bin"].join(File::PATH_SEPARATOR)
      with_env("HOME" => home, "RBENV_ROOT" => nil, "PATH" => path, "BUNDLER_ORIG_PATH" => path, "ASDF_DATA_DIR" => nil) do
        parts = observe(client_for(root), root)["PATH"].split(File::PATH_SEPARATOR)
        assert_includes parts, rbenv_bin
        refute_includes parts, asdf_bin
        assert_equal File.join(home, ".asdf", "shims"), parts.first
      end
    end
  end

  def test_spawn_drops_a_custom_rbenv_bin_when_that_root_has_shims
    Dir.mktmpdir("daemon-env") do |root|
      rbenv = File.join(root, "custom-rbenv")
      FileUtils.mkdir_p(File.join(rbenv, "shims"))
      version_bin = File.join(rbenv, "versions", "3.3.0", "bin")
      other = File.join(root, "home", ".rbenv", "versions", "3.3.0", "bin")
      path = [version_bin, other, "/usr/bin"].join(File::PATH_SEPARATOR)
      with_env(
        "HOME" => File.join(root, "home"),
        "RBENV_ROOT" => rbenv,
        "PATH" => path,
        "BUNDLER_ORIG_PATH" => path
      ) do
        parts = observe(client_for(root), root)["PATH"].split(File::PATH_SEPARATOR)
        refute_includes parts, version_bin
        assert_includes parts, other
        assert_equal File.join(rbenv, "shims"), parts.first
      end
    end
  end

  def test_spawn_drops_a_custom_asdf_bin_when_that_data_dir_has_shims
    Dir.mktmpdir("daemon-env") do |root|
      data = File.join(root, "asdf-data")
      FileUtils.mkdir_p(File.join(data, "shims"))
      asdf_bin = File.join(data, "installs", "ruby", "3.3.0", "bin")
      path = [asdf_bin, "/usr/bin"].join(File::PATH_SEPARATOR)
      with_env("HOME" => root, "ASDF_DATA_DIR" => data, "PATH" => path, "BUNDLER_ORIG_PATH" => path) do
        parts = observe(client_for(root), root)["PATH"].split(File::PATH_SEPARATOR)
        refute_includes parts, asdf_bin
        assert_equal File.join(data, "shims"), parts.first
      end
    end
  end

  # #491: a missing-file error names the load variables the daemon dropped,
  # never their values, and only when the user set them.
  def test_missing_file_error_names_dropped_load_variables
    cause = "LoadError: cannot load such file -- support/helpers"
    client = client_for(Dir.pwd)
    hint = ->(text) { client.send(:with_load_env_hint, text) }

    with_env("RUBYOPT" => "-Itest -rsecret-token-123", "RUBYLIB" => nil, "BUNDLER_ORIG_RUBYOPT" => nil,
             "BUNDLER_ORIG_RUBYLIB" => nil) do
      noted = hint.(cause)
      assert noted.start_with?(cause)
      assert_includes noted, "does not pass RUBYOPT to the app"
      assert_equal "#{cause} (the daemon does not pass RUBYOPT to the app; if the missing file is in a directory " \
                   "set there, add that directory to load_path: in .mutineer.yml, or pass -I DIR to mutineer (it replaces that list), " \
                   "see #{Mutineer::DaemonClient::LOAD_PATH_GUIDE})", noted
      assert Mutineer::DaemonClient::LOAD_PATH_GUIDE.end_with?("/docs/rails-setup.md#extra-load-paths")
      refute_includes noted, "secret-token-123"
      assert_equal "RuntimeError: boom", hint.("RuntimeError: boom")
      assert_nil hint.(nil)
    end

    %w[Itest -wItest].each do |opt|
      with_env("RUBYOPT" => opt, "BUNDLER_ORIG_RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLER_ORIG_RUBYLIB" => nil) do
        assert_includes hint.(cause), "does not pass RUBYOPT to the app", opt
      end
    end

    # A RUBYOPT with no -I adds no load path, so the note would mislead.
    with_env("RUBYOPT" => "--yjit -W0 -rIcu", "BUNDLER_ORIG_RUBYOPT" => nil, "RUBYLIB" => nil,
             "BUNDLER_ORIG_RUBYLIB" => nil) do
      assert_equal cause, hint.(cause)
    end

    # Bundler's own RUBYOPT is not the user's: the saved value says unset.
    with_env("RUBYOPT" => "-rbundler/setup", "BUNDLER_ORIG_RUBYOPT" => UNSET, "RUBYLIB" => nil,
             "BUNDLER_ORIG_RUBYLIB" => nil) do
      assert_equal cause, hint.(cause)
    end

    with_env("RUBYOPT" => "-rbundler/setup", "BUNDLER_ORIG_RUBYOPT" => "-Itest", "RUBYLIB" => "lib",
             "BUNDLER_ORIG_RUBYLIB" => nil) do
      assert_includes hint.(cause), "does not pass RUBYOPT or RUBYLIB to the app"
    end

    with_env("RUBYOPT" => nil, "BUNDLER_ORIG_RUBYOPT" => nil, "RUBYLIB" => "lib", "BUNDLER_ORIG_RUBYLIB" => nil) do
      assert_includes hint.(cause), "does not pass RUBYLIB to the app"
    end

    # Under `bundle exec`, the user's RUBYLIB is the saved one.
    with_env("RUBYOPT" => nil, "BUNDLER_ORIG_RUBYOPT" => nil, "RUBYLIB" => "/bundler/lib",
             "BUNDLER_ORIG_RUBYLIB" => "test/support") do
      assert_includes hint.(cause), "does not pass RUBYLIB to the app"
    end
  end

  # #535: the note is one text for the daemon and for --test-command. Its
  # default is the inside of the 1.10.0 note, byte for byte.
  def test_load_env_note_is_the_shared_note_text
    with_env("RUBYOPT" => nil, "BUNDLER_ORIG_RUBYOPT" => nil, "RUBYLIB" => "lib", "BUNDLER_ORIG_RUBYLIB" => nil) do
      assert_equal "the daemon does not pass RUBYLIB to the app; if the missing file is in a directory set there, " \
                   "add that directory to load_path: in .mutineer.yml, or pass -I DIR to mutineer (it replaces that list), " \
                   "see #{Mutineer::DaemonClient::LOAD_PATH_GUIDE}", Mutineer::DaemonClient.load_env_note
      assert Mutineer::DaemonClient.load_env_note(who: "--test-command", to: "the command")
                                   .start_with?("--test-command does not pass RUBYLIB to the command; ")
    end
    with_env("RUBYOPT" => nil, "BUNDLER_ORIG_RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLER_ORIG_RUBYLIB" => nil) do
      assert_nil Mutineer::DaemonClient.load_env_note
    end
  end

  # The hint reaches #last_cause through #request, not only the helper.
  def test_request_adds_the_hint_to_the_error_cause
    client = client_for(Dir.pwd)
    client.instance_variable_set(:@stdin, StringIO.new)
    reply = { "id" => 7, "verdict" => "error", "details" => "LoadError: cannot load such file -- support/helpers" }
    with_env("RUBYOPT" => "-Itest/support", "BUNDLER_ORIG_RUBYOPT" => nil, "RUBYLIB" => nil,
             "BUNDLER_ORIG_RUBYLIB" => nil) do
      client.stub(:send_line, nil) do
        client.stub(:read_line, reply) do
          assert_equal "error", client.request(id: 7, payload: {}, tests: [], timeout: 1)
        end
      end
    end
    assert_includes client.last_cause, "does not pass RUBYOPT to the app"
  end

  private

  def client_for(root, boot: { project_root: root })
    Mutineer::DaemonClient.new(boot: boot, app_root: root, gemfile: File.join(root, "Gemfile"))
  end

  def write_parent_require(root)
    path = File.join(root, "parent_only.rb")
    File.write(path, "ENV['MUTINEER_PARENT_CODE_LOADED'] = 'yes'\n")
    path
  end

  # Current values are the tool's. BUNDLER_ORIG_* is what the app had before
  # the tool's Bundler activated. A gem home, BUNDLE_PATH, or BUNDLE_WITHOUT
  # is kept only when that saved key exists. RUBYOPT and RUBYLIB are always
  # dropped, including a saved value.
  def tool_over_app_env(root, injected, version_bin, chruby_bin, app_home)
    {
      "RUBYOPT" => "-r#{injected}",
      "BUNDLER_ORIG_RUBYOPT" => UNSET,
      "RUBYLIB" => File.join(root, "tool-only-lib"),
      "BUNDLER_ORIG_RUBYLIB" => UNSET,
      "GEM_HOME" => "/tmp/mutineer-tool-gems",
      "BUNDLER_ORIG_GEM_HOME" => app_home,
      "BUNDLER_SETUP" => "/tmp/tool/bundler/setup",
      "BUNDLER_ORIG_BUNDLER_SETUP" => UNSET,
      "BUNDLE_WITHOUT" => "tool_group",
      "BUNDLER_ORIG_BUNDLE_WITHOUT" => "app_required_group",
      "BUNDLE_APP_CONFIG" => app_home,
      "BUNDLE_GEMFILE" => "/tmp/MutineerToolGemfile",
      "BUNDLER_ORIG_BUNDLE_GEMFILE" => UNSET,
      "RBENV_VERSION" => "3.3.6",
      "ASDF_RUBY_VERSION" => "3.2.1",
      "MUTINEER_APP_PROBE" => "kept",
      "RAILS_ENV" => nil,
      "PATH" => [
        version_bin, "#{version_bin}/", chruby_bin, ENV.fetch("PATH")
      ].join(File::PATH_SEPARATOR),
      "BUNDLER_ORIG_PATH" => [
        version_bin, "#{version_bin}/", chruby_bin, "/usr/bin"
      ].join(File::PATH_SEPARATOR)
    }
  end

  def observe(client, root)
    script = <<~'RUBY'
      require "json"
      keys = %w[
        RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_PATH BUNDLE_WITHOUT BUNDLE_APP_CONFIG
        BUNDLE_GEMFILE BUNDLER_SETUP BUNDLER_VERSION RBENV_VERSION ASDF_RUBY_VERSION RAILS_ENV
        PARALLEL_WORKERS MUTINEER_PARENT_CODE_LOADED MUTINEER_APP_PROBE
      ]
      data = keys.to_h { |key| [key, ENV[key]] }
      data["PATH"] = ENV["PATH"]
      print JSON.generate(data)
    RUBY
    stdin, stdout, stderr, wait = Open3.popen3(
      client.send(:app_env), RUBY, "-e", script,
      unsetenv_others: true, chdir: root
    )
    stdin.close
    out = stdout.read
    err = stderr.read
    status = wait.value
    flunk "child exited #{status&.exitstatus}: #{err}" unless status&.success?

    JSON.parse(out)
  ensure
    stdout&.close
    stderr&.close
  end
end
