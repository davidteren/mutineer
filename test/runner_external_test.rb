# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "shellwords"

# #27 (U4/U5): end-to-end for the external --test-command backend. Drives the real
# bin against copied fixtures, using `ruby <test_file>` as the app's suite (the
# fixture tests `require "minitest/autorun"`, so they exit 0 on pass / 1 on fail —
# exactly the external contract). No real Rails app needed in CI.
class RunnerExternalTest < Minitest::Test
  ROOT     = File.expand_path("..", __dir__)
  BIN      = File.join(ROOT, "bin", "mutineer")
  FIXTURES = File.expand_path("fixtures", __dir__)
  RUBY     = RbConfig.ruby

  def mutineer(*args, chdir:, env: {})
    Open3.capture3(env, RUBY, "-I#{File.join(ROOT, 'lib')}", BIN, *args, chdir: chdir)
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
      assert_includes err, "Only exit 1 counts as a kill"
      refute_includes err, "no Minitest or RSpec summary line"
      assert_match(%r{\[mutineer\] \d+/\d+ mutants \(\d+%\)}, err,
                   "external backend must emit progress on stderr")
    end
  end

  # #495: --test-command has no boot and no coverage phase. The clean run is
  # the clean check, and each mutant's seconds is its command run.
  def test_timing_has_no_boot_or_coverage_phase
    with_project("calculator_strong_test.rb") do |proj|
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--format", "json",
                                  "--test-command", "#{RUBY} %{files}", chdir: proj)
      assert_equal 0, status.exitstatus, err
      doc = JSON.parse(out)
      timing = doc.fetch("timing")
      # Hash equality also fails when a key is missing: a null phase stays a key.
      assert_equal({ "boot_seconds" => nil, "coverage_seconds" => nil }, timing.slice("boot_seconds", "coverage_seconds"))
      %w[clean_check_seconds mutants_seconds total_seconds].each { |k| assert_kind_of Numeric, timing[k], k }
      assert_operator timing["total_seconds"], :>=, timing["mutants_seconds"]
      refute_empty doc["killed"]
      doc["killed"].each { |entry| assert_kind_of Numeric, entry["seconds"], entry["id"] }
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

  # #303: with LC_ALL=C Ruby reads the source as US-ASCII. A non-ASCII line
  # must still be mutated and scored through --test-command.
  def test_non_ascii_source_scores_under_an_ascii_locale
    with_project("calculator_weak_test.rb") do |proj|
      path = File.join(proj, "calculator.rb")
      File.write(path, File.read(path).sub("    a + b\n", "    a + b # caf\u00e9\n"))
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                                  "--test-command", "#{RUBY} %{files}", chdir: proj,
                                  env: { "LC_ALL" => "C", "LANG" => nil })
      assert_equal 0, status.exitstatus, err.b
      assert_includes out.b, "66.7%"
    end
  end

  def test_external_runner_writes_the_mutant_with_the_declared_source_encoding
    Dir.mktmpdir("mutineer-latin1-external") do |dir|
      src = File.join(dir, "encoding_calc.rb")
      File.binwrite(src, <<~RUBY.encode(Encoding::ISO_8859_1))
        # encoding: ISO-8859-1
        class Latin1ExternalEncodingExample
          def value
            # caf\u00E9
            'caf\u00E9'.upcase
          end
        end
      RUBY

      original = File.binread(src)
      parsed_source = Mutineer::Parser.parse_file(src).source.source
      subject = Mutineer::Project.discover([src]).first
      mutation = Mutineer::Mutators::CallToReceiver.new.mutations_for(subject, parsed_source).first
      expected = mutation.apply(parsed_source).b
      external_run = lambda do |*_args, **_kwargs|
        assert_equal expected, File.binread(src)
        Mutineer::Result.killed
      end

      result = Mutineer::ExternalBackend.stub(:run, external_run) do
        Mutineer::Runner.run_external(subject, mutation, "unused", [],
                                      timeout: 30, verbose: false, check_summary: false)
      end

      assert_predicate result, :killed?
      assert_equal original, File.binread(src), "external execution must restore the source bytes"
    end
  end

  def test_latin1_source_mutation_runs_through_external_backend
    skip "external process groups are unavailable on Windows" if Gem.win_platform?

    Dir.mktmpdir("mutineer-latin1-external") do |dir|
      src = File.join(dir, "encoding_calc.rb")
      test = File.join(dir, "encoding_calc_test.rb")
      File.binwrite(src, <<~RUBY.encode(Encoding::ISO_8859_1))
        # encoding: ISO-8859-1
        class Latin1ExternalEncodingExample
          def value
            # caf\u00E9
            'caf\u00E9'.upcase
          end
        end
      RUBY
      File.write(test, <<~RUBY)
        require "minitest/autorun"
        require_relative "encoding_calc"

        class Latin1ExternalEncodingExampleTest < Minitest::Test
          def test_value
            assert_equal "CAF\u00C9", Latin1ExternalEncodingExample.new.value.encode(Encoding::UTF_8)
          end
        end
      RUBY

      parsed_source = Mutineer::Parser.parse_file(src).source.source
      subject = Mutineer::Project.discover([src]).first
      mutation = Mutineer::Mutators::CallToReceiver.new.mutations_for(subject, parsed_source).first

      result = Mutineer::Runner.run_external(subject, mutation, "#{RUBY} %{files}", [test],
                                             timeout: 30, verbose: false, check_summary: true)

      assert_predicate result, :killed?, "expected killed, got #{result.status} (#{result.details})"
      assert_equal parsed_source, Mutineer::Parser.parse_file(src).source.source,
                   "external execution must restore the original source bytes"
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

  # #99: a second external run must refuse while the first owns the source.
  def test_second_run_refuses_while_first_owns_source
    with_project("calculator_strong_test.rb") do |proj|
      path = File.join(proj, "calculator.rb")
      original = File.binread(path)
      rd_ready, wr_ready = IO.pipe
      rd_resume, wr_resume = IO.pipe
      pid = fork do
        rd_ready.close
        wr_resume.close
        Mutineer::FileSwap.with(path, original) do
          wr_ready.write("1")
          wr_ready.close
          rd_resume.read(1)
        end
        exit! 0
      end
      wr_ready.close
      rd_resume.close
      rd_ready.read(1)
      _out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                   "--test-command", "#{RUBY} %{files}", chdir: proj)
      wr_resume.write("1")
      wr_resume.close
      wait_child(pid)
      assert_equal 1, status.exitstatus, err
      assert_match(/another mutineer run owns/, err)
      assert_equal original, File.binread(path)
    end
  end

  # A command that fails on the UNMUTATED tree is a broken environment: abort
  # before scoring (exit 1), name the diagnosis, run zero mutants.
  def test_smoke_failure_aborts
    with_project("calculator_strong_test.rb") do |proj|
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                  "--test-command", "#{RUBY} -e exit(1) %{files}", chdir: proj)
      assert_equal 1, status.exitstatus
      assert_match(/unmutated suite is not green/, err)
      refute_match(/mutation score/i, out)
    end
  end

  # #292: the clean run prints a Minitest summary, so a mutant run that exits 1
  # with no summary (the mutant crashed the suite at load) scores error, not
  # killed. The wrapper runs the suite on the clean tree and crashes otherwise.
  def test_exit_one_without_summary_scores_error_after_summary_smoke
    with_project("calculator_strong_test.rb") do |proj|
      original = File.read(File.join(proj, "calculator.rb"))
      wrapper = File.join(proj, "wrapper.rb")
      File.write(wrapper, <<~RUBY)
        exit 1 unless File.read(#{File.join(proj, 'calculator.rb').dump}) == #{original.dump}
        load ARGV.fetch(0)
      RUBY
      out, err, = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--format", "json",
                           "--test-command", "#{RUBY} #{wrapper} %{files}", chdir: proj)
      summary = JSON.parse(out).fetch("summary")
      assert_equal 0, summary.fetch("killed"), err
      assert_equal 6, summary.fetch("errored"), err
      refute_includes err, "no Minitest or RSpec summary line"
    end
  end

  # #515, AE1: the clean run prints its summary at a line start, so each
  # mutant run needs one there. A mutant run whose only failing summary is in
  # a Minitest -v test name scores error, with the reason, not killed.
  def test_failing_summary_away_from_a_line_start_scores_error
    with_project("calculator_strong_test.rb") do |proj|
      original = File.read(File.join(proj, "calculator.rb"))
      wrapper = File.join(proj, "wrapper.rb")
      File.write(wrapper, <<~RUBY)
        unless File.read(#{File.join(proj, 'calculator.rb').dump}) == #{original.dump}
          puts "FakeTest#test_x = 9 runs, 9 assertions, 1 failures, 0 errors, 0 skips = 0.00 s = ."
          puts "2 runs, 2 assertions, 0 failures, 0 errors, 0 skips"
          exit 1
        end
        load ARGV.fetch(0)
      RUBY
      out, err, = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--format", "json",
                           "--test-command", "#{RUBY} #{wrapper} %{files}", chdir: proj)
      doc = JSON.parse(out)
      assert_equal 0, doc.dig("summary", "killed"), err
      assert_equal 6, doc.dig("summary", "errored"), err
      doc.fetch("no_verdict").each { |row| assert_includes row["details"], "not at the start of a line" }
    end
  end

  # #515, AE2: a wrapper that puts a prefix before each line leaves no
  # summary at a line start, so matching stays at any position and each
  # failing test still kills.
  def test_wrapper_that_prefixes_each_line_still_kills
    with_project("calculator_strong_test.rb") do |proj|
      wrapper = File.join(proj, "prefix.rb")
      File.write(wrapper, <<~RUBY)
        require "open3"
        out, status = Open3.capture2e(RbConfig.ruby, *ARGV)
        out.each_line { |line| print "app | \#{line}" }
        exit status.exitstatus
      RUBY
      out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--format", "json",
                                  "--test-command", "#{RUBY} #{wrapper} %{files}", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal 6, JSON.parse(out).dig("summary", "killed"), err
      refute_includes err, "no Minitest or RSpec summary line"
    end
  end

  # #516, AE3: a real chain, `weak suite && strong suite`. A stand-in for
  # SimpleCov's minimum_coverage gate runs after the first suite: on a
  # mutated tree it prints SimpleCov's gate message and exits 2, as SimpleCov
  # does in Minitest.after_run. The weak suite kills 4 of the 6 mutants. The
  # other 2 pass it, the gate stops the chain, and the strong suite, which
  # would kill them, never runs: error, not survived.
  def test_simplecov_gate_that_stops_a_chain_of_suites_scores_error
    with_project("calculator_strong_test.rb") do |proj|
      FileUtils.cp(File.join(FIXTURES, "calculator_weak_test.rb"), proj)
      calc = File.join(proj, "calculator.rb")
      gate = File.join(proj, "coverage_gate.rb")
      File.write(gate, <<~RUBY)
        require "minitest"
        Minitest.after_run do
          next if File.read(#{calc.dump}) == #{File.read(calc).dump}

          puts "SimpleCov failed with exit 2 due to a coverage related error"
          exit 2
        end
      RUBY
      chain = File.join(proj, "chain.rb")
      File.write(chain, <<~RUBY)
        system(RbConfig.ruby, "-r", #{gate.dump}, #{File.join(proj, 'calculator_weak_test.rb').dump}) || exit($?.exitstatus)
        system(RbConfig.ruby, #{File.join(proj, 'calculator_strong_test.rb').dump}) || exit($?.exitstatus)
      RUBY
      out, err, = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb", "--format", "json",
                           "--test-command", "#{RUBY} #{chain} %{files}", chdir: proj)
      doc = JSON.parse(out)
      assert_equal 4, doc.dig("summary", "killed"), err
      assert_equal 0, doc.dig("summary", "survived"), err
      assert_equal 2, doc.dig("summary", "errored"), err
      doc.fetch("no_verdict").each do |row|
        assert_includes row["details"], "printed 1 summary line where the clean run printed 2, after a SimpleCov coverage gate"
      end
    end
  end

  # #292: a clean run with no summary line keeps the exit-code rule and says so once.
  def test_no_summary_on_clean_run_warns_once
    with_project("calculator_strong_test.rb") do |proj|
      _out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                   "--test-command", "#{RUBY} -e exit(0) %{files}", chdir: proj)
      assert_equal 0, status.exitstatus, err
      assert_equal 1, err.scan("no Minitest or RSpec summary line").size, err
    end
  end

  # #338: an order-dependent suite (fixtures/order_dependent) under a command
  # with no fixed seed. Mutineer cannot see the fixture's own default seed, so
  # it warns once, names the seed, and still scores the run.
  def test_random_order_on_clean_run_warns_once
    with_order_dependent_project do |proj|
      out, err, status = mutineer("run", "ledger.rb", "--test", "ledger_test.rb", "--format", "json",
                                  "--test-command", "#{RUBY} %{files}", chdir: proj, env: { "SEED" => nil, "TESTOPTS" => nil })
      assert_equal 0, status.exitstatus, err
      assert_equal 1, err.scan("printed a Minitest seed (1)").size, err
      assert_includes err, "set SEED=1 before the mutineer command"
      assert_equal 1, JSON.parse(out).dig("summary", "killed"), err
    end
  end

  # #338: SEED in Mutineer's environment fixes the order for the clean run and
  # every mutant run, so no warning prints and the verdict is the same.
  def test_fixed_seed_on_clean_run_does_not_warn
    with_order_dependent_project do |proj|
      out, err, status = mutineer("run", "ledger.rb", "--test", "ledger_test.rb", "--format", "json",
                                  "--test-command", "#{RUBY} %{files}", chdir: proj, env: { "SEED" => "1", "TESTOPTS" => nil })
      assert_equal 0, status.exitstatus, err
      refute_includes err, "seed (1)"
      assert_equal 1, JSON.parse(out).dig("summary", "killed"), err
    end
  end

  # #338: the fixture really depends on order. Seed 2 runs test_total first,
  # so the clean run fails and the run stops before scoring.
  def test_order_dependent_fixture_fails_in_another_order
    with_order_dependent_project do |proj|
      _out, err, status = mutineer("run", "ledger.rb", "--test", "ledger_test.rb",
                                   "--test-command", "#{RUBY} %{files}", chdir: proj, env: { "SEED" => "2", "TESTOPTS" => nil })
      assert_equal 1, status.exitstatus, err
      assert_match(/unmutated suite is not green/, err)
    end
  end

  # Copies the order-dependent fixture into a temp project.
  def with_order_dependent_project
    Dir.mktmpdir("mutineer-ext-order") do |proj|
      FileUtils.cp(Dir.glob(File.join(FIXTURES, "order_dependent", "*.rb")), proj)
      yield proj
    end
  end

  # PR #183 review: --test-command never reads --timeout, so it says so.
  def test_timeout_flag_warns_that_it_has_no_effect
    with_project("calculator_strong_test.rb") do |proj|
      _out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                   "--timeout", "30", "--test-command", "#{RUBY} %{files}", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_includes err, "--timeout has no effect with --test-command"
      refute_includes err, "--capture-timeout"

      _out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_strong_test.rb",
                                   "--cache-dir", "tmp/c", "--test-command", "#{RUBY} %{files}", chdir: proj)
      assert_equal 0, status.exitstatus
      assert_includes err, "--cache-dir has no effect with --test-command"
    end
  end

  # The child sees PARALLEL_WORKERS=1, DISABLE_SPRING=1 and
  # DISABLE_BOOTSNAP_COMPILE_CACHE=1 on every spawn.
  # A user value is replaced once, not once per mutant.
  def test_test_command_replaces_parallel_workers_and_disables_spring_and_bootsnap_cache
    with_project("calculator_strong_test.rb") do |proj|
      log = File.join(proj, "child-env.log")
      probe = File.join(proj, "probe.rb")
      File.write(probe, <<~RUBY)
        File.open(#{log.dump}, "a") do |file|
          file.puts([ENV["PARALLEL_WORKERS"], ENV["DISABLE_SPRING"], ENV["DISABLE_BOOTSNAP_COMPILE_CACHE"]].inspect)
        end
      RUBY
      _out, err, status = mutineer(
        "run", "calculator.rb", "--test", "calculator_strong_test.rb",
        "--test-command", "#{RUBY} #{probe} %{files}",
        chdir: proj, env: { "PARALLEL_WORKERS" => "8" }
      )
      assert_equal 0, status.exitstatus, "stdout:#{_out}\nstderr:#{err}"
      assert_equal ['["1", "1", "1"]'], File.readlines(log).map(&:strip).uniq
      assert_equal 1, err.scan('PARALLEL_WORKERS was "8"').size
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

  # #288: --verbose prints the test command's output, which can quote
  # DATABASE_URL.
  def test_verbose_output_hides_the_password
    url = "postgres://u:s3cret@ho st/db"
    saved = ENV.fetch("DATABASE_URL", nil)
    ENV["DATABASE_URL"] = url
    command = "#{RUBY} -e #{Shellwords.escape('puts ENV.fetch("DATABASE_URL"); exit 1')} %{files}"

    _, err = capture_io { Mutineer::ExternalBackend.run(command, [], timeout: 30, verbose: true) }

    assert_includes err, "[REDACTED]"
    refute_includes err, "s3cret"
  ensure
    ENV["DATABASE_URL"] = saved
  end

  # #392: a mutant that Ruby cannot load is skipped before the file swap, so
  # the command never runs and the source file keeps its text.
  def test_a_mutant_ruby_cannot_load_is_skipped_without_running_the_command
    with_project("calculator_strong_test.rb") do |proj|
      path = File.join(proj, "calculator.rb")
      source = File.read(path)
      subject = Mutineer::Project.discover([path]).find { |s| Mutineer::Mutators::Arithmetic.new.mutations_for(s, source).any? }
      broken = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first.with(replacement: "(")
      marker = File.join(proj, "command_ran")
      command = "#{RUBY} -e #{Shellwords.escape("File.write(#{marker.inspect}, 1)")}"
      result = Mutineer::Runner.run_external(subject, broken, command, [], timeout: 30, verbose: false, check_summary: false)
      assert_predicate result, :skipped?
      refute_path_exists marker, "the command must not run for an invalid mutant"
      assert_equal source, File.read(path)
    end
  end
end
