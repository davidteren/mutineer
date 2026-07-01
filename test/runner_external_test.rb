# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# #27 (U4/U5): end-to-end for the external --test-command backend. Drives the real
# bin against copied fixtures, using `ruby <test_file>` as the app's suite (the
# fixture tests `require "minitest/autorun"`, so they exit 0 on pass / 1 on fail —
# exactly the external contract). No real Rails app needed in CI.
class RunnerExternalTest < Minitest::Test
  ROOT     = File.expand_path("..", __dir__)
  BIN      = File.join(ROOT, "bin", "mutineer")
  FIXTURES = File.expand_path("fixtures", __dir__)
  RUBY     = RbConfig.ruby

  def mutineer(*args, chdir:)
    Open3.capture3(RUBY, "-I#{File.join(ROOT, 'lib')}", BIN, *args, chdir: chdir)
  end

  def with_project(test_file)
    Dir.mktmpdir("mutineer-ext-proj") do |proj|
      %w[calculator.rb].each { |f| FileUtils.cp(File.join(FIXTURES, f), File.join(proj, f)) }
      FileUtils.cp(File.join(FIXTURES, test_file), File.join(proj, test_file))
      yield proj
    end
  end

  # Strong suite kills all 6 arithmetic mutants -> 100%, exit 0. Confirms no
  # in-process boot happened and the upper-bound disclosure is printed.
  def test_strong_suite_scores_100
    with_project("calculator_strong_test.rb") do |proj|
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  "--test-command", "#{RUBY} %{files}", chdir: proj)
      assert_equal 0, status.exitstatus, "stdout:#{out}\nstderr:#{err}"
      assert_match(/100(\.0)?%/, out)
      assert_match(/upper bound/, err)
    end
  end

  # Weak suite: 2 of 6 arithmetic mutants survive -> 66.7%. Threshold defaults to
  # 0 so exit stays 0; survivors are reported.
  def test_weak_suite_reports_survivors
    with_project("calculator_weak_test.rb") do |proj|
      out, _err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                                   "--test-command", "#{RUBY} %{files}", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_match(/66\.7%/, out)
    end
  end

  # The working tree is intact after a run — no mutated bytes, no leftover backup.
  def test_source_restored_after_run
    with_project("calculator_strong_test.rb") do |proj|
      original = File.binread(File.join(proj, "calculator.rb"))
      mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
               "--test-command", "#{RUBY} %{files}", chdir: proj)
      assert_equal original, File.binread(File.join(proj, "calculator.rb"))
      assert_empty Dir.glob(File.join(proj, "*.mutineer-backup"))
    end
  end

  # A command that fails on the UNMUTATED tree is a broken environment: abort
  # before scoring (exit 1), name the diagnosis, run zero mutants.
  def test_smoke_failure_aborts
    with_project("calculator_strong_test.rb") do |proj|
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  "--test-command", "#{RUBY} -e exit(1) %{files}", chdir: proj)
      assert_equal 1, status.exitstatus
      assert_match(/environment looks broken/, err)
      refute_match(/mutation score/i, out)
    end
  end

  # KTD-5: --jobs > 1 is forced to 1 with a notice (no per-worker DB isolation yet).
  def test_jobs_forced_to_one
    with_project("calculator_strong_test.rb") do |proj|
      _out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                   "--jobs", "4", "--test-command", "#{RUBY} %{files}", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_match(/forcing --jobs 1/, err)
    end
  end
end
