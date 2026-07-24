# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "mutineer/external_backend"

# #27 (U3): the external backend spawns the user's test command in the app's own
# runtime and maps its exit status to a verdict. Uses `ruby -e` as a stand-in for
# a real suite so the tests are hermetic.
class ExternalBackendTest < Minitest::Test
  Backend = Mutineer::ExternalBackend
  RUBY = RbConfig.ruby

  # Real commands (`bundle exec rails test %{files}`) carry no embedded quotes, so
  # a script file is the faithful stand-in for a suite whose body has spaces/quotes.
  def with_script(body)
    Dir.mktmpdir("mutineer-ext") do |dir|
      path = File.join(dir, "suite.rb")
      File.write(path, body)
      yield path
    end
  end

  # argv construction — %{files} expands to N separate tokens, no shell.
  def test_build_argv_expands_files_to_separate_tokens
    argv = Backend.build_argv("bundle exec rails test %{files}", ["test/a_test.rb", "test/b_test.rb"])
    assert_equal ["bundle", "exec", "rails", "test", "test/a_test.rb", "test/b_test.rb"], argv
  end

  def test_build_argv_keeps_space_containing_path_intact
    argv = Backend.build_argv("run %{files}", ["dir with space/a_test.rb"])
    assert_equal ["run", "dir with space/a_test.rb"], argv
  end

  # verdict mapping
  def test_exit_zero_is_survived
    result = Backend.run("#{RUBY} -e exit(0) %{files}", ["x"], timeout: 30)
    assert_predicate result, :survived?
  end

  def test_exit_one_is_killed
    result = Backend.run("#{RUBY} -e exit(1) %{files}", ["x"], timeout: 30)
    assert_predicate result, :killed?
  end

  def test_other_nonzero_is_killed
    result = Backend.run("#{RUBY} -e exit(3) %{files}", ["x"], timeout: 30)
    assert_predicate result, :killed?
  end

  def test_signal_death_is_error_not_killed
    # Self-SIGKILL: exitstatus is nil; must not inflate kill rate.
    result = Backend.run("#{RUBY} -e 'Process.kill(:KILL, Process.pid)' %{files}", ["x"], timeout: 30)
    assert_predicate result, :error?
    refute_predicate result, :killed?
  end

  def test_timeout_is_timeout_and_fast
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, err = capture_io do
      @result = Backend.run("#{RUBY} -e sleep(10) %{files}", ["x"], timeout: 1)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_predicate @result, :timeout?
    assert_operator elapsed, :<, 5, "should kill near the 1s deadline, not wait 10s"
    assert_match(/exceeded 1s/, err)
  end

  # Non-bundler env is still inherited (RAILS_ENV-style vars set on the Mutineer
  # command). Bundler/gem injection is scrubbed separately (#32).
  def test_env_is_inherited
    ENV["MUTINEER_ENV_PROBE"] = "1"
    with_script(%(exit(ENV["MUTINEER_ENV_PROBE"] == "1" ? 0 : 1))) do |path|
      assert_predicate Backend.run("#{RUBY} #{path} %{files}", ["x"], timeout: 30), :survived?
    end
  ensure
    ENV.delete("MUTINEER_ENV_PROBE")
  end

  def test_child_env_strips_gem_and_bundler_injection
    ENV["GEM_HOME"] = "/tmp/mutineer-fake-gems"
    ENV["BUNDLE_GEMFILE"] = "/tmp/MutineerGemfile"
    ENV["RBENV_VERSION"] = "3.4.9"
    env = Backend.child_env
    assert_nil env["GEM_HOME"]
    assert_nil env["BUNDLE_GEMFILE"]
    assert_nil env["RBENV_VERSION"]
  ensure
    ENV.delete("GEM_HOME")
    ENV.delete("BUNDLE_GEMFILE")
    ENV.delete("RBENV_VERSION")
  end

  def test_child_env_scrubs_rbenv_version_bin_from_path
    version_bin = File.expand_path("~/.rbenv/versions/3.4.9/bin")
    original_path = ENV["PATH"]
    ENV["PATH"] = "#{version_bin}:/usr/bin:/bin"
    ENV["RBENV_VERSION"] = "3.4.9"
    env = Backend.child_env
    refute_includes env["PATH"].split(File::PATH_SEPARATOR), version_bin
    assert_includes env["PATH"], "/usr/bin"
  ensure
    ENV["PATH"] = original_path if original_path
    ENV.delete("RBENV_VERSION")
  end

  # --verbose surfaces the child's captured output; default run stays quiet on a kill.
  def test_verbose_prints_output_on_kill_default_quiet
    with_script(%(STDOUT.puts "boom-detail"\nexit 1\n)) do |path|
      cmd = "#{RUBY} #{path} %{files}"
      _out, err = capture_io { Backend.run(cmd, ["x"], timeout: 30, verbose: true) }
      assert_match(/boom-detail/, err)

      _out2, err2 = capture_io { Backend.run(cmd, ["x"], timeout: 30) }
      refute_match(/boom-detail/, err2)
    end
  end

  # smoke check — green returns elapsed, non-green raises with the output tail.
  def test_smoke_check_green_returns_elapsed
    elapsed = Backend.smoke_check!("#{RUBY} -e exit(0) %{files}", ["x"], timeout: 30)
    assert_kind_of Float, elapsed
  end

  def test_smoke_check_non_green_raises_with_output
    with_script(%(STDOUT.puts "db down"\nexit 1\n)) do |path|
      err = assert_raises(Mutineer::SmokeCheckError) do
        Backend.smoke_check!("#{RUBY} #{path} %{files}", ["x"], timeout: 30)
      end
      assert_match(/environment looks broken/, err.message)
      assert_match(/db down/, err.message)
    end
  end

  def test_smoke_check_ruby_version_mismatch_gives_targeted_hint
    msg = "Bundler::RubyVersionMismatch: Your Ruby version is 3.4.9, " \
          "but your Gemfile specified 3.1.6"
    with_script(%(STDERR.puts #{msg.inspect}\nexit 1\n)) do |path|
      err = assert_raises(Mutineer::SmokeCheckError) do
        Backend.smoke_check!("#{RUBY} #{path} %{files}", ["x"], timeout: 30)
      end
      assert_match(/Ruby version mismatch/, err.message)
      assert_match(/3\.4\.9/, err.message)
      assert_match(/3\.1\.6/, err.message)
      assert_match(/version manager/, err.message)
      refute_match(/check DB, RAILS_ENV/, err.message)
    end
  end
end
