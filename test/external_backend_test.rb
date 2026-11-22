# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"
require "open3"
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

  # #292: only exit 1 is the test-failure code, as in Isolation.decode. A
  # custom failure code or a wrapper's 128+N signal exit is not a kill.
  def test_other_nonzero_is_error_not_killed
    [3, 137].each do |code|
      result = Backend.run("#{RUBY} -e exit(#{code}) %{files}", ["x"], timeout: 30)
      assert_predicate result, :error?, "exit #{code}"
      assert_equal "test-command exited #{code} (only exit 1 counts as a kill; " \
                   "check RSpec --failure-exit-code, a coverage gate, or your wrapper)", result.details
    end
  end

  # #480: an errored --test-command run names the last non-blank output
  # line, without colour codes and redacted, so every report shows a cause.
  def test_errored_run_names_the_last_output_line
    out = "first\n\e[31mpostgres://u:hunter2@db/x refused\e[0m\n\n"
    with_script(%(STDOUT.write #{out.dump}\nexit 3\n)) do |path|
      details = Backend.run("#{RUBY} #{path} %{files}", ["x"], timeout: 30).details
      assert_match(/; last output line: postgres:\/\/u:\S+@db\/x refused\z/, details)
      refute_includes details, "hunter2"
      refute_includes details, "\e["
    end
  end

  # Exit-1 outputs that score killed with the summary check on (#292).
  EXIT_ONE_KILLED = [
    "1 runs, 1 assertions, 1 failures, 0 errors, 0 skips\n",
    "2 runs, 1 assertions, 0 failures, 1 errors, 0 skips\n",
    "3 tests, 3 assertions, 1 failures, 0 errors, 0 skips\n", # minitest-reporters
    "2 examples, 1 failure\n",
    "\e[31m3 examples, 2 failures\e[0m\n",
    # A wrapper that runs two suites: a kill in either one is a kill.
    "2 runs, 2 assertions, 0 failures, 0 errors, 0 skips\n4 examples, 1 failure\n",
    # Minitest started its tests, then code under test called exit or abort.
    "Run options: --seed 1\n\n# Running:\n\n",
    # A wrapper's first suite passed, then its second one stopped mid-test.
    "# Running:\n\n2 runs, 2 assertions, 0 failures, 0 errors, 0 skips\n# Running:\n\n",
    "\e[31m5 tests, 5 assertions, \e[0m\e[31m1 failures\e[0m, 0 errors, 0 skips\n",
    "café ✓\n1 runs, 1 assertions, 1 failures, 0 errors, 0 skips\n\xFF\n"
  ].freeze

  # Exit-1 outputs with no failing test. An RSpec file that raises while
  # loading prints a summary line with no failing example, the case #246
  # scores as error in process.
  EXIT_ONE_ERROR = [
    "0 examples, 0 failures, 1 error occurred outside of examples\n",
    # RSpec prints this when code under test calls exit 1 mid-example.
    "2 examples, 0 failures\n",
    "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n",
    "# Running:\n\n3 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n",
    "2 runs, 2 assertions, 0 failures, 0 errors, 0 skips\n" \
      "0 examples, 0 failures, 1 error occurred outside of examples\n"
  ].freeze

  # SimpleCov's gate message.
  GATE = "SimpleCov failed with exit 2 due to a coverage related error\n"

  # Exit-2 outputs and their verdict.
  SIMPLECOV_GATE = {
    "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n#{GATE}" => :survived?,
    "4 examples, 0 failures\n#{GATE}" => :survived?,
    "3 runs, 3 assertions, 1 failures, 0 errors, 0 skips\n#{GATE}" => :killed?,
    "4 examples, 1 failure\n#{GATE}" => :killed?,
    "0 examples, 0 failures, 1 error occurred outside of examples\n#{GATE}" => :error?,
    GATE => :error?, # no recognized summary line: a failing run cannot be ruled out
    "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n" => :error?
  }.freeze

  # The two summary modes of a clean run that printed a summary line (#515).
  MODES = [true, :line].freeze

  # #292: with summary checking on, exit 1 is a kill only when a Minitest or
  # RSpec summary line reports a failing test.
  def run_exit_one(output, check_summary: true)
    with_script(%(STDOUT.write #{output.dump}\nexit 1\n)) do |path|
      Backend.run("#{RUBY} #{path} %{files}", ["x"], timeout: 30, check_summary: check_summary)
    end
  end

  def test_exit_one_without_summary_is_error_when_checking
    MODES.each do |mode|
      result = run_exit_one("LoadError: cannot load such file\n", check_summary: mode)
      assert_predicate result, :error?, mode.inspect
      assert_match(/exited 1 but its output shows no failing test/, result.details)
    end
  end

  def test_exit_one_without_summary_is_killed_when_not_checking
    assert_predicate run_exit_one("LoadError\n", check_summary: false), :killed?
  end

  # #515: both summary modes give the same verdict on line-start output.
  def test_exit_one_with_failing_summary_is_killed
    EXIT_ONE_KILLED.product(MODES).each do |output, mode|
      assert_predicate run_exit_one(output, check_summary: mode), :killed?, "#{mode.inspect} #{output.inspect}"
    end
  end

  def test_exit_one_with_no_failing_test_in_summary_is_error
    EXIT_ONE_ERROR.product(MODES).each do |output, mode|
      assert_predicate run_exit_one(output, check_summary: mode), :error?, "#{mode.inspect} #{output.inspect}"
    end
  end

  # The verdict of +output+ with exit +code+, without a process: the stub
  # hands Backend.run the output as spawn_capture reads it.
  def verdict(output, code, check_summary)
    read = output.b.force_encoding(Encoding::UTF_8).scrub
    Backend.stub(:spawn_capture, [:exited, code, read, 0.0]) do
      Backend.run("unused %{files}", ["x"], timeout: 30, check_summary: check_summary)
    end
  end

  # #515, the rule on every table row: under :line, a summary line that does
  # not start a line counts as no summary; under true it counts as before.
  def test_line_mode_reads_a_moved_summary_line_as_no_summary
    summary = ->(line) { Backend.summary_line?(Backend.summary_text(line)) }
    rows = EXIT_ONE_KILLED.map { |o| [o, 1] } + EXIT_ONE_ERROR.map { |o| [o, 1] } + SIMPLECOV_GATE.keys.map { |o| [o, 2] }
    rows.each do |output, code|
      lines = output.b.lines
      without = lines.reject(&summary).join
      ["  ", "app | "].each do |prefix|
        moved = lines.map { |l| summary.call(l) ? "#{prefix}#{l}" : l }.join
        assert_equal verdict(without, code, :line).status, verdict(moved, code, :line).status,
                     ":line #{prefix.inspect} #{output.inspect}"
        assert_equal verdict(output, code, true).status, verdict(moved, code, true).status,
                     "true #{prefix.inspect} #{output.inspect}"
      end
    end
  end

  # Failing summary-like text that does not start a line (#342 limit 4).
  FAKE_FAILING_SUMMARIES = [
    "FakeTest#test_x = 9 runs, 9 assertions, 1 failures, 0 errors, 0 skips = 0.00 s = .\n", # Minitest -v
    ".9 runs, 9 assertions, 1 failures, 0 errors, 0 skips\n", # a puts after a progress dot
    "  reports 2 examples, 1 failure\n", # an RSpec documentation example name
    "app | 3 runs, 3 assertions, 1 failures, 0 errors\n" # a prefixed line
  ].freeze

  # #515: each fake is followed by the real passing summary and exit 1.
  def test_line_mode_drops_a_failing_summary_that_does_not_start_a_line
    passing = "2 runs, 2 assertions, 0 failures, 0 errors, 0 skips\n"
    FAKE_FAILING_SUMMARIES.each do |fake|
      result = run_exit_one(fake + passing, check_summary: :line)
      assert_predicate result, :error?, fake
      assert_includes result.details, "a failing summary is in its output, but not at the start of a line", fake
      assert_predicate run_exit_one(fake + passing, check_summary: true), :killed?, fake
    end
    details = run_exit_one(passing, check_summary: :line).details
    assert_includes details, "shows no failing test"
    refute_includes details, "not at the start of a line"
  end

  # #515: after a SimpleCov gate, a failing summary away from the line start
  # is no survivor proof: a chain of a plain suite and a prefixed one.
  def test_line_mode_does_not_score_a_moved_failing_summary_survived_after_the_gate
    output = "2 runs, 2 assertions, 0 failures, 0 errors, 0 skips\n" \
             "app | 1 runs, 1 assertions, 1 failures, 0 errors, 0 skips\n#{GATE}"
    with_script(%(STDOUT.write #{output.dump}\nexit 2\n)) do |path|
      cmd = "#{RUBY} #{path} %{files}"
      [1, 2].each do |clean|
        result = Backend.run(cmd, ["x"], timeout: 30, check_summary: :line, clean_summaries: clean)
        assert_predicate result, :error?, "clean #{clean}"
        assert_includes result.details, "exited 2 and a failing summary is in its output, but not at the start of a line"
      end
      assert_predicate Backend.run(cmd, ["x"], timeout: 30, check_summary: true, clean_summaries: 1), :killed?
    end
  end

  # A progress bar that redraws its line ends it with "\r", and Windows ends
  # each line with "\r\n". Both are a line start.
  def test_line_mode_counts_a_summary_after_a_carriage_return
    ["progress\r3 runs, 3 assertions, 1 failures, 0 errors\n",
     "Run options: --seed 1\r\n\r\n# Running:\r\n\r\nF\r\n\r\n1 runs, 1 assertions, 1 failures, 0 errors, 0 skips\r\n",
     "Run options: --seed 1\r\n\r\n# Running:\r\n\r\n"].each do |output|
      assert_predicate run_exit_one(output, check_summary: :line), :killed?, output.inspect
    end
  end

  # Under :line the "# Running:" line also counts only at a line start.
  def test_line_mode_reads_the_running_line_only_at_a_line_start
    output = "2 runs, 2 assertions, 0 failures, 0 errors\nnote: # Running:\n"
    assert_predicate run_exit_one(output, check_summary: :line), :error?
    assert_predicate run_exit_one(output, check_summary: true), :killed?
  end

  # A run that stopped during a Minitest -v test: the name line holds a
  # passing summary, and no real summary follows "# Running:".
  def test_line_mode_sees_a_run_that_stopped_during_a_verbose_test
    output = "# Running:\n\nFakeTest#test_1 runs, 1 assertions, 0 failures, 0 errors = "
    assert_predicate run_exit_one(output, check_summary: :line), :killed?
    assert_predicate run_exit_one(output, check_summary: true), :error?
  end

  # SimpleCov's minimum_coverage gate replaces the exit code (exit 2). Under
  # Minitest it runs after a failing test too, so a failing summary is still a
  # kill. With a passing summary no test caught the mutant: it survives, as in
  # process, where the fork exits before that hook. Without SimpleCov's line,
  # exit 2 may be code under test calling exit 2, which scores error.
  def test_simplecov_gate_exit_follows_the_summary
    SIMPLECOV_GATE.each do |output, verdict|
      with_script(%(STDOUT.write #{output.dump}\nexit 2\n)) do |path|
        cmd = "#{RUBY} #{path} %{files}"
        MODES.each do |mode|
          assert_predicate Backend.run(cmd, ["x"], timeout: 30, check_summary: mode), verdict, "#{mode.inspect} #{output.inspect}"
        end
        assert_predicate Backend.run(cmd, ["x"], timeout: 30), verdict, "check off: #{output.inspect}"
      end
    end
  end

  # #516: after the gate, a passing run survives only when it printed as
  # many summary lines as the clean run. With fewer, a suite of a chain did
  # not run, so the mutant has no verdict.
  def test_simplecov_gate_compares_the_summary_count_with_the_clean_run
    passing = "3 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n"
    [
      [passing + GATE, 1, :survived?],
      [passing + GATE, 2, :error?],
      [passing * 2 + GATE, 2, :survived?],
      [passing * 3 + GATE, 2, :survived?],
      ["3 runs, 3 assertions, 1 failures, 0 errors, 0 skips\n#{GATE}", 2, :killed?],
      [passing + GATE, 0, :survived?],
      ["0 examples, 0 failures, 1 error occurred outside of examples\n#{GATE}", 1, :error?]
    ].each do |output, clean, verdict|
      with_script(%(STDOUT.write #{output.dump}\nexit 2\n)) do |path|
        MODES.each do |mode|
          result = Backend.run("#{RUBY} #{path} %{files}", ["x"], timeout: 30, check_summary: mode, clean_summaries: clean)
          assert_predicate result, verdict, "#{mode.inspect} #{clean} #{output.inspect}"
        end
      end
    end
    result = verdict(passing + GATE, 2, :line)
    assert_predicate result, :survived?, "the default clean_summaries of 0 keeps the 1.9.0 rule"
    with_script(%(STDOUT.write #{(passing + GATE).dump}\nexit 2\n)) do |path|
      details = Backend.run("#{RUBY} #{path} %{files}", ["x"], timeout: 30, check_summary: :line, clean_summaries: 2).details
      assert_includes details, "printed 1 summary line where the clean run printed 2, after a SimpleCov coverage gate"
      assert_includes details, "turn the gate off for mutation runs"
    end
  end

  # 126 (cannot execute) and 127 (command not found) come from a wrapper such
  # as `bundle exec` that could not start the suite: no test ran, so no kill.
  def test_cannot_run_exit_codes_are_error_not_killed
    [126, 127].each do |code|
      result = Backend.run("#{RUBY} -e exit(#{code}) %{files}", ["x"], timeout: 30)
      assert_predicate result, :error?, "exit #{code}"
      refute_predicate result, :killed?
    end
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

  # Rails parallelize, Spring and Bootsnap read these in the test-command child.
  def test_child_env_pins_parallel_workers_and_disables_spring_and_bootsnap_cache
    prior = ENV["PARALLEL_WORKERS"]
    ENV["PARALLEL_WORKERS"] = "8"
    env = Backend.child_env
    assert_equal "1", env["PARALLEL_WORKERS"]
    assert_equal "1", env["DISABLE_SPRING"]
    assert_equal "1", env["DISABLE_BOOTSNAP_COMPILE_CACHE"]
    assert_equal "8", ENV["PARALLEL_WORKERS"]
  ensure
    prior.nil? ? ENV.delete("PARALLEL_WORKERS") : ENV["PARALLEL_WORKERS"] = prior
  end

  # child_env must pass nil (not omit keys) so Process.spawn unsets them.
  def test_child_env_strips_gem_and_bundler_injection
    prior = {
      "GEM_HOME" => ENV["GEM_HOME"],
      "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"],
      "RBENV_VERSION" => ENV["RBENV_VERSION"]
    }
    ENV["GEM_HOME"] = "/tmp/mutineer-fake-gems"
    ENV["BUNDLE_GEMFILE"] = "/tmp/MutineerGemfile"
    ENV["RBENV_VERSION"] = "3.4.9"
    env = Backend.child_env
    assert env.key?("GEM_HOME")
    assert_nil env["GEM_HOME"]
    assert_nil env["BUNDLE_GEMFILE"]
    assert_nil env["RBENV_VERSION"]
  ensure
    prior.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Concrete version bins (optional trailing slash) leave PATH so shims can win.
  def test_child_env_scrubs_rbenv_version_bin_from_path
    version_bin = File.expand_path("~/.rbenv/versions/3.4.9/bin")
    prior_path = ENV["PATH"]
    prior_rbenv = ENV["RBENV_VERSION"]
    ENV["PATH"] = "#{version_bin}:#{version_bin}/:/usr/bin:/bin"
    ENV["RBENV_VERSION"] = "3.4.9"
    env = Backend.child_env
    parts = env["PATH"].split(File::PATH_SEPARATOR)
    refute_includes parts, version_bin
    refute_includes parts, "#{version_bin}/"
    assert_includes env["PATH"], "/usr/bin"
  ensure
    ENV["PATH"] = prior_path if prior_path
    prior_rbenv.nil? ? ENV.delete("RBENV_VERSION") : ENV["RBENV_VERSION"] = prior_rbenv
  end

  # Spawn merges env; nil must clear a leaked RBENV_VERSION in the child.
  def test_spawn_unsets_rbenv_version_via_nil
    prior = ENV["RBENV_VERSION"]
    ENV["RBENV_VERSION"] = "3.4.9"
    out = Tempfile.create("mutineer_env")
    pid = Process.spawn(Backend.child_env, RUBY, "-e",
                        "print ENV['RBENV_VERSION'].inspect",
                        out: out, err: out)
    wait_child(pid)
    out.rewind
    assert_equal "nil", out.read.strip
  ensure
    prior.nil? ? ENV.delete("RBENV_VERSION") : ENV["RBENV_VERSION"] = prior
    if out
      out.close
      File.unlink(out.path) rescue nil # rubocop:disable Style/RescueModifier
    end
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
  def test_smoke_check_green_returns_elapsed_and_no_summary
    elapsed, mode = Backend.smoke_check!("#{RUBY} -e exit(0) %{files}", ["x"], timeout: 30)
    assert_kind_of Float, elapsed
    assert_equal false, mode
  end

  # #515: the clean run picks the summary mode that Backend.run gets.
  def test_smoke_check_reports_the_summary_mode
    {
      "4 runs, 4 assertions, 0 failures, 0 errors, 0 skips" => :line,
      "3 examples, 0 failures" => :line,
      "app | 3 examples, 0 failures" => true,
      "app | 3 examples, 0 failures\n4 runs, 4 assertions, 0 failures, 0 errors, 0 skips" => :line
    }.each do |text, expected|
      with_script(%(puts #{text.dump}\n)) do |path|
        _elapsed, mode = Backend.smoke_check!("#{RUBY} #{path} %{files}", ["x"], timeout: 30)
        assert_equal expected, mode, text
      end
    end
  end

  # #516: the clean run's summary count, in the mode it picked.
  def test_smoke_check_reports_the_summary_count
    passing = "4 runs, 4 assertions, 0 failures, 0 errors, 0 skips"
    {
      "no summary" => 0,
      passing => 1,
      "#{passing}\n3 examples, 0 failures" => 2,
      "#{passing}\napp | 3 examples, 0 failures" => 1,
      "app | #{passing}" => 1
    }.each do |text, expected|
      with_script(%(puts #{text.dump}\n)) do |path|
        _elapsed, _mode, _order, count = Backend.smoke_check!("#{RUBY} #{path} %{files}", ["x"], timeout: 30)
        assert_equal expected, count, text
      end
    end
  end

  # The real output and exit status of a Minitest or RSpec run. The child
  # keeps this test's bundle, so a Minitest 6 run reads Minitest 6. One
  # test's name holds failing-summary-like text. Minitest -v and RSpec
  # documentation format print that name away from a line start.
  def real_runner_output(format, fail:)
    Dir.mktmpdir("mutineer-real-runner") do |dir|
      File.write(File.join(dir, "fake_test.rb"), <<~TEST)
        require "minitest/autorun"
        class FakeSummaryTest < Minitest::Test
          define_method("test_9 runs, 9 assertions, 1 failures, 0 errors, 0 skips") { assert true }
          def test_real = assert(ENV["MUTINEER_FAKE_FAIL"].nil?)
        end
      TEST
      File.write(File.join(dir, "fake_spec.rb"), <<~SPEC)
        RSpec.describe "suite" do
          it("reports 2 examples, 1 failure") { expect(1).to eq(1) }
          it("real") { expect(ENV["MUTINEER_FAKE_FAIL"]).to be_nil }
        end
      SPEC
      argv = case format
             when :minitest then ["fake_test.rb"]
             when :minitest_verbose then ["fake_test.rb", "-v"]
             else ["-e", 'require "rspec/core"; exit RSpec::Core::Runner.run(ARGV)', "--",
                   "--format", format.to_s, "fake_spec.rb"]
             end
      # HOME and XDG_CONFIG_HOME keep ~/.rspec out of the run.
      env = { "MUTINEER_FAKE_FAIL" => (fail ? "1" : nil), "SEED" => "1", "TESTOPTS" => nil, "SPEC_OPTS" => nil,
              "HOME" => dir, "XDG_CONFIG_HOME" => dir }
      out, status = Open3.capture2e(env, RUBY, *argv, chdir: dir)
      [out, status.exitstatus]
    end
  end

  # #515, R4: the default reporters print their summary at a line start, so
  # a passing run picks :line and a failing run still scores killed under it.
  # The passing run has exactly one line-start summary, the real one, and in
  # the formats that print test names the failing-like name does not count.
  def test_real_runner_summaries_start_a_line
    %i[minitest minitest_verbose progress documentation].each do |format|
      out, code = real_runner_output(format, fail: false)
      assert_equal 0, code, out
      text = Backend.summary_text(out)
      assert_equal 1, Backend.summary_count(text, line: true), "#{format}: #{out}"
      refute Backend.failure_reported?(text, line: true), "#{format}: #{out}"
      assert Backend.failure_reported?(text), "#{format}: #{out}" if %i[minitest_verbose documentation].include?(format)
      with_script(%(STDOUT.write #{out.dump}\nexit #{code}\n)) do |path|
        _elapsed, mode = Backend.smoke_check!("#{RUBY} #{path} %{files}", ["x"], timeout: 30)
        assert_equal :line, mode, "#{format}: #{out}"
      end

      out, code = real_runner_output(format, fail: true)
      assert_equal 1, code, out
      assert Backend.failure_reported?(Backend.summary_text(out), line: true), "#{format}: #{out}"
      with_script(%(STDOUT.write #{out.dump}\nexit #{code}\n)) do |path|
        result = Backend.run("#{RUBY} #{path} %{files}", ["x"], timeout: 30, check_summary: :line)
        assert_predicate result, :killed?, "#{format}: #{out}"
      end
    end
  end

  # #338: the runner and seed of a shuffled run are reported, unless a seed is given.
  def test_smoke_check_reports_random_order
    { "Run options: --seed 4242" => :minitest, "Randomized with seed 4242" => :rspec }.each do |line, runner|
      with_script(%(puts #{line.dump}\n)) do |path|
        with_env("SEED" => nil, "TESTOPTS" => nil, "SPEC_OPTS" => nil) do
          _elapsed, _summary, order = Backend.smoke_check!("#{RUBY} #{path} %{files}", ["x"], timeout: 30)
          assert_equal [runner, "4242"], order, line
        end
      end
    end
  end

  def test_random_order_is_nil_when_the_order_is_fixed
    text = "Run options: --seed 4242\n"
    rspec = "Randomized with seed 4242\n"
    with_env("SEED" => nil, "TESTOPTS" => nil, "SPEC_OPTS" => nil) do
      assert_nil Backend.random_order("rspec --order defined %{files}", "3 examples, 0 failures\n")
      assert_nil Backend.random_order("ruby %{files} --seed 7", text)
      assert_nil Backend.random_order("env SEED=7 ruby %{files}", text)
      assert_nil Backend.random_order("rspec --seed 7 %{files}", rspec)
      assert_nil Backend.random_order("ruby %{files} -s 7", text)
      assert_nil Backend.random_order("ruby %{files} -s7", text)
      with_env("TESTOPTS" => "-s7") { assert_nil Backend.random_order("rake test", text) }
      refute_nil Backend.random_order("ruby %{files} -skip", text)
      assert_nil Backend.random_order("rspec --order rand:7 %{files}", rspec)
      assert_equal [:minitest, "4242"], Backend.random_order("ruby %{files}", text)
      with_env("SEED" => "7") { assert_nil Backend.random_order("ruby %{files}", text) }
      with_env("TESTOPTS" => "--seed=7") { assert_nil Backend.random_order("rake test", text) }
      with_env("SPEC_OPTS" => "--seed 7") { assert_nil Backend.random_order("rspec %{files}", rspec) }
    end
  end

  # #368: minitest-reporters prints its own seed line; a plain "seed" word in other output is no seed line.
  def test_random_order_reads_the_minitest_reporters_seed_line
    with_env("SEED" => nil, "TESTOPTS" => nil, "SPEC_OPTS" => nil) do
      reporters = "Started with run options --seed 4242\n"
      assert_equal [:minitest, "4242"], Backend.random_order("ruby %{files}", "# Running tests with run options --seed 4242:\n")
      assert_equal [:minitest, "4242"], Backend.random_order("ruby %{files}", reporters)
      assert_nil Backend.random_order("ruby %{files} --seed 7", reporters)
      assert_nil Backend.random_order("ruby %{files}", "the seed 4242 is fixed\n")
    end
  end

  # #368: a seed in .rspec or .rspec-local is a fixed seed, in any spelling RSpec takes.
  def test_random_order_sees_a_seed_in_the_rspec_option_files
    rspec = "Randomized with seed 4242\n"
    with_env("SEED" => nil, "TESTOPTS" => nil, "SPEC_OPTS" => nil) do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          assert_equal [:rspec, "4242"], Backend.random_order("rspec %{files}", rspec)
          File.write(".rspec", "--require spec_helper\n--color\n")
          assert_equal [:rspec, "4242"], Backend.random_order("rspec %{files}", rspec)
          File.write(".rspec", "# --seed 7\n  # --order rand:7\n")
          assert_equal [:rspec, "4242"], Backend.random_order("rspec %{files}", rspec), "commented-out seed"
          File.delete(".rspec")
          ["--seed 7", "--order rand:7", "--order random:7"].each do |line|
            File.write(".rspec", "#{line}\n")
            assert_nil Backend.random_order("rspec %{files}", rspec), line
            File.delete(".rspec")
            File.write(".rspec-local", "#{line}\n")
            assert_nil Backend.random_order("rspec %{files}", rspec), "local #{line}"
            File.delete(".rspec-local")
          end
        end
      end
    end
  end

  # #522: the last RSpec order option decides, read in RSpec's order:
  # .rspec, .rspec-local, the command, SPEC_OPTS. Each row was run for real
  # with RSpec; "random" rows shuffled, the others kept the seed.
  def test_random_order_follows_the_rspec_option_order
    rspec = "Randomized with seed 4242\n"
    random = [:rspec, "4242"]
    [
      [{ ".rspec" => "--seed 7" }, "rspec %{files}", nil, nil],
      [{ ".rspec" => "--seed 7" }, "rspec --order rand %{files}", nil, random],
      [{ ".rspec" => "--seed 7" }, "rspec %{files}", "--order rand", random],
      [{ ".rspec" => "--seed 7", ".rspec-local" => "--order rand" }, "rspec %{files}", nil, random],
      [{ ".rspec" => "--seed 7" }, "rspec --options other.opts %{files}", nil, random],
      [{ ".rspec" => "--seed 7" }, "rspec -O other.opts %{files}", nil, random],
      # RSpec reads --options only from the command line, not from SPEC_OPTS.
      [{ ".rspec" => "--seed 7" }, "rspec %{files}", "--options other.opts", nil],
      [{}, "rspec --seed 7 --order rand %{files}", nil, random],
      [{}, "rspec --order rand --seed 7 %{files}", nil, nil],
      [{}, "rspec --order=rand:9 %{files}", nil, nil],
      [{}, "rspec --order rand %{files}", "--seed 5", nil],
      [{ ".rspec" => "--order rand" }, "rspec --seed 3 %{files}", nil, nil]
    ].each do |files, command, spec_opts, expected|
      with_env("SEED" => nil, "TESTOPTS" => nil, "SPEC_OPTS" => spec_opts) do
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            files.each { |name, body| File.write(name, "#{body}\n") }
            got = Backend.random_order(command, rspec)
            row = "#{files.inspect} #{command.inspect} SPEC_OPTS=#{spec_opts.inspect}"
            expected ? assert_equal(expected, got, row) : assert_nil(got, row)
          end
        end
      end
    end
  end

  # #368: an unreadable .rspec counts as no seed; it must not abort the run.
  def test_random_order_ignores_an_unreadable_rspec_file
    with_env("SEED" => nil, "TESTOPTS" => nil, "SPEC_OPTS" => nil) do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write(".rspec", "--seed 7\n")
          File.stub(:readlines, ->(*) { raise Errno::EACCES }) do
            assert_equal [:rspec, "4242"], Backend.random_order("rspec %{files}", "Randomized with seed 4242\n")
          end
        end
      end
    end
  end

  # A command that runs a seeded Minitest suite and then an unseeded RSpec
  # suite still reports the RSpec order.
  def test_random_order_checks_each_runner_in_a_combined_run
    text = "Run options: --seed 1\n2 runs, 2 assertions, 0 failures, 0 errors\nRandomized with seed 4242\n"
    with_env("SEED" => "1", "TESTOPTS" => nil, "SPEC_OPTS" => nil) do
      assert_equal [:rspec, "4242"], Backend.random_order("bin/run-both %{files}", text)
    end
  end

  # RSpec ignores SEED and TESTOPTS, so they do not hide its random order.
  def test_random_order_ignores_minitest_settings_under_rspec
    with_env("SEED" => "7", "TESTOPTS" => "--seed=7", "SPEC_OPTS" => nil) do
      assert_equal [:rspec, "4242"], Backend.random_order("env SEED=7 rspec %{files}", "Randomized with seed 4242\n")
    end
  end

  def test_smoke_check_non_green_raises_with_output
    with_script(%(STDOUT.puts "db down"\nexit 1\n)) do |path|
      err = assert_raises(Mutineer::SmokeCheckError) do
        Backend.smoke_check!("#{RUBY} #{path} %{files}", ["x"], timeout: 30)
      end
      assert_match(/unmutated suite is not green/, err.message)
      assert_match(/db down/, err.message)
    end
  end

  # #303: with LANG unset the captured output reads as US-ASCII. Non-ASCII
  # output from a failing suite must reach the smoke error, not crash it.
  def test_smoke_check_non_ascii_output_under_an_ascii_locale
    with_script(%(STDOUT.puts "caf\\u00e9 down"\nexit 1\n)) do |path|
      err = with_ascii_default_external do
        assert_raises(Mutineer::SmokeCheckError) do
          Backend.smoke_check!("#{RUBY} #{path} %{files}", ["x"], timeout: 30)
        end
      end
      assert_includes err.message, "caf\u00e9 down"
    end
  end

  # Test output need not be valid UTF-8 (a Latin-1 message, say). The smoke
  # error still carries the text, with the bad byte shown as \xNN.
  def test_smoke_check_invalid_utf8_output_is_replaced_not_raised
    with_script(%(STDOUT.binmode\nSTDOUT.write("bad \\xFF byte\\n")\nexit 1\n)) do |path|
      err = assert_raises(Mutineer::SmokeCheckError) do
        Backend.smoke_check!("#{RUBY} #{path} %{files}", ["x"], timeout: 30)
      end
      assert_includes err.message, "bad \\xFF byte"
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
