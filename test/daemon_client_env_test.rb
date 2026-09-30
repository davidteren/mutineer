# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "test_helper"
require "mutineer/daemon_client"

# #100: Open3 keeps a key the spawn hash omits. These tests spawn a real child
# with the daemon's environment. A check that the hash lacks the key would
# still pass while the child inherited the tool setting.
class DaemonClientEnvTest < Minitest::Test
  RUBY = RbConfig.ruby

  def test_spawn_drops_tool_ruby_bundler_and_version_pins
    Dir.mktmpdir("daemon-env") do |root|
      injected = write_parent_require(root)
      version_bin = File.expand_path("~/.rbenv/versions/9.9.9/bin")
      with_env(tool_leak_env(root, injected, version_bin)) do
        observed = observe(client_for(root), root)

        assert_nil observed["MUTINEER_PARENT_CODE_LOADED"]
        assert_nil observed["RUBYOPT"]
        assert_nil observed["BUNDLER_SETUP"]
        assert_nil observed["RUBYLIB"]
        assert_nil observed["GEM_HOME"]
        assert_nil observed["BUNDLE_PATH"]
        assert_nil observed["BUNDLE_WITHOUT"]
        assert_nil observed["RBENV_VERSION"]
        assert_nil observed["ASDF_RUBY_VERSION"]
        assert_equal File.join(root, "Gemfile"), observed["BUNDLE_GEMFILE"]
        assert_equal "kept", observed["MUTINEER_APP_PROBE"]
        parts = observed["PATH"].split(File::PATH_SEPARATOR)
        refute_includes parts, version_bin
        refute_includes parts, "#{version_bin}/"
      end
    end
  end

  def test_spawn_applies_explicit_ruby_pin_and_rails_test_env
    Dir.mktmpdir("daemon-env") do |root|
      gemfile = File.join(root, "app.gemfile")
      with_env("RBENV_VERSION" => "3.4.9", "RAILS_ENV" => nil) do
        client = Mutineer::DaemonClient.new(
          boot: { rails: true }, app_root: root, ruby_version: "3.3.6", gemfile: gemfile
        )
        observed = observe(client, root)

        assert_equal "3.3.6", observed["RBENV_VERSION"]
        assert_equal gemfile, observed["BUNDLE_GEMFILE"]
        assert_equal "test", observed["RAILS_ENV"]
      end
    end
  end

  def test_spawn_keeps_existing_rails_env
    Dir.mktmpdir("daemon-env") do |root|
      with_env("RAILS_ENV" => "production") do
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

  def tool_leak_env(root, injected, version_bin)
    {
      "RUBYOPT" => "-r#{injected}",
      "RUBYLIB" => File.join(root, "tool-only-lib"),
      "GEM_HOME" => "/tmp/mutineer-tool-gems",
      "BUNDLE_PATH" => "/tmp/mutineer-tool-bundle",
      "BUNDLE_WITHOUT" => "app_required_group",
      "BUNDLE_GEMFILE" => "/tmp/MutineerToolGemfile",
      "RBENV_VERSION" => "3.4.9",
      "ASDF_RUBY_VERSION" => "3.4.9",
      "MUTINEER_APP_PROBE" => "kept",
      "RAILS_ENV" => nil,
      "PATH" => "#{version_bin}#{File::PATH_SEPARATOR}#{version_bin}/#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"
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
        RUBYOPT RUBYLIB GEM_HOME BUNDLE_PATH BUNDLE_WITHOUT BUNDLE_GEMFILE
        BUNDLER_SETUP RBENV_VERSION ASDF_RUBY_VERSION RAILS_ENV
        MUTINEER_PARENT_CODE_LOADED MUTINEER_APP_PROBE
      ]
      data = keys.to_h { |key| [key, ENV[key]] }
      data["PATH"] = ENV["PATH"]
      print JSON.generate(data)
    RUBY
    stdin, stdout, stderr, wait = Open3.popen3(client.send(:app_env), RUBY, "-e", script, chdir: root)
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
