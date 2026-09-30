# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
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
      version_bin = File.expand_path("~/.rbenv/versions/9.9.9/bin")
      chruby_bin = File.expand_path("~/.rubies/app-ruby/bin")
      app_home = "/usr/local/bundle"
      with_env(tool_over_app_env(root, injected, version_bin, chruby_bin, app_home)) do
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
        assert_nil observed["RUBYOPT"]
      end
    end
  end

  # The flag has to be on the real spawn call. A helper that adds it only in
  # the test would stay green if spawn_daemon dropped it.
  def test_spawn_daemon_passes_unsetenv_others
    root = Dir.mktmpdir("daemon-env")
    seen = {}
    client = client_for(root)
    Open3.stub(:popen3, lambda { |*_args, **kwargs|
      seen.replace(kwargs)
      raise Errno::ENOENT
    }) do
      error = assert_raises(Mutineer::DaemonBootError) { client.send(:spawn_daemon) }
      assert_match(/ENOENT/, error.message)
    end
    assert_equal true, seen[:unsetenv_others]
    assert_equal root, seen[:chdir]
  ensure
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  def test_spawn_keeps_existing_rails_env
    Dir.mktmpdir("daemon-env") do |root|
      with_env("RAILS_ENV" => "production", "BUNDLER_ORIG_RUBYOPT" => UNSET) do
        observed = observe(client_for(root, boot: { "rails" => true }), root)
        assert_equal "production", observed["RAILS_ENV"]
      end
    end
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
  # the tool's Bundler activated. Keys with no saved original are the app's.
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
      "BUNDLE_WITHOUT" => "app_required_group",
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

  def with_env(updates)
    prior = updates.each_key.to_h { |key| [key, ENV[key]] }
    updates.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    prior&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def observe(client, root)
    script = <<~'RUBY'
      require "json"
      keys = %w[
        RUBYOPT RUBYLIB GEM_HOME BUNDLE_WITHOUT BUNDLE_APP_CONFIG BUNDLE_GEMFILE
        BUNDLER_SETUP RBENV_VERSION ASDF_RUBY_VERSION RAILS_ENV
        MUTINEER_PARENT_CODE_LOADED MUTINEER_APP_PROBE
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
