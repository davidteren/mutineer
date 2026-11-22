# frozen_string_literal: true

module Mutineer
  class CoverageMap
    # Starts a child Ruby, reads its result channel, and builds the script text
    # that the child runs for a clean check or a coverage capture.
    #
    # These are private methods of {Mutineer::CoverageMap}. They read and write
    # its instance variables.
    #
    # @api private
    module ChildScripts
      private

      # Runs `script` in a fresh `ruby -` that reads the script from stdin. The
      # child's stdout goes to File::NULL, so test output never reaches the user
      # or the result. With `result: true`, the child writes its result as one
      # line to fd {RESULT_FD}, a pipe that only the script uses. The child's
      # stderr is the parent's stderr, so warnings from the script reach the
      # user. A wall clock of `timeout` bounds the whole call (see
      # {#await_child}), so a hung test cannot wedge the run.
      #
      # The parent reads one line, not until EOF: a process that a test leaves
      # running can inherit fd {RESULT_FD} (a `fork` without `exec` keeps it
      # despite close-on-exec) and hold the pipe open long after the child exits.
      # A clean check reports only through its exit status, so it gets no pipe.
      #
      # @api private
      # @param script [String] Ruby script text.
      # @param result [Boolean] whether to open the result pipe on fd {RESULT_FD}.
      # @param timeout [Numeric] seconds before the child is killed.
      # @return [Array(Process::Status, String)] the exit status and the line the
      #   child wrote to fd {RESULT_FD} (`""` without one); `[nil, ""]` after a
      #   timeout.
      def spawn_script(script, result: true, timeout: @capture_timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        script_rd, script_wr = IO.pipe
        result_rd, result_wr = IO.pipe if result
        options = { in: script_rd, out: File::NULL, pgroup: true }
        options[RESULT_FD] = result_wr if result
        pid = Process.spawn(RbConfig.ruby, "-", **options)
        script_rd.close
        result_wr&.close
        begin
          script_wr.write(script)
        rescue Errno::EPIPE
          # The child exited before reading its script; await_child still reaps it.
        end
        script_wr.close
        status, out = await_child(pid, deadline) { read_result_line(result_rd) if result }
        [status, out.to_s]
      ensure
        [script_rd, script_wr, result_rd, result_wr].compact.each { |io| io.close unless io.closed? }
      end

      # Reads the one result line a {#spawn_script} child writes to fd
      # {RESULT_FD}. The line is JSON and may name a non-ASCII path. The pipe
      # follows the locale, so under `LC_ALL=C` those bytes arrive tagged
      # US-ASCII and `JSON.parse` raises. The bytes are UTF-8 (#346).
      #
      # @api private
      # @param io [IO] the parent end of the result pipe.
      # @return [String] the line, or `""` at end of file.
      def read_result_line(io)
        line = io.gets
        return "" unless line

        line.dup.force_encoding(Encoding::UTF_8)
      end

      # Reads the one Marshal object a forked capture child writes, without
      # waiting for end of file.
      #
      # @api private
      # @param io [IO] the parent end of the binary result pipe.
      # @return [Object, nil] the object, or nil when the child wrote none.
      def read_marshal(io)
        Marshal.load(io)
      rescue EOFError
        nil
      end

      # Waits for capture child `pid`, which leads its own process group, while
      # a thread runs the block to read the child's result. One `deadline`
      # bounds the run, the read, and the reap. Past it, the whole group gets
      # SIGKILL, so a process the test started does not outlive a hung capture.
      # Process.detach owns reaping. The same deadline and group kill as
      # DaemonServer#wait_verdict, plus a reader, because the child reports
      # through a pipe.
      #
      # A child that exits before the deadline has written its result, so the
      # reader gets the time left, and at least {RESULT_GRACE} seconds, to finish.
      #
      # @api private
      # @param pid [Integer] child pid, also its process group id.
      # @param deadline [Float] a CLOCK_MONOTONIC time.
      # @yieldreturn [Object] what the child wrote.
      # @return [Array(Process::Status, Object)] the exit status and the block's
      #   value (nil when the reader did not finish); `[nil, nil]` after a timeout.
      def await_child(pid, deadline, &read)
        waiter = Process.detach(pid)
        reader = Thread.new(&read)
        reader.report_on_exception = false
        return [nil, nil] unless waiter.join(remaining(deadline))

        [waiter.value, reader.join([remaining(deadline), RESULT_GRACE].max)&.value]
      ensure
        kill_group(pid, waiter) if waiter&.alive?
        reader&.kill
      end

      # Seconds left before `deadline`, never negative.
      #
      # @api private
      # @param deadline [Float] a CLOCK_MONOTONIC time.
      # @return [Float]
      def remaining(deadline)
        [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
      end

      # Ruby source that opens the result channel in a {#spawn_script} child. The
      # script runs it first, so no file that a test opens can take fd
      # {RESULT_FD}. Close-on-exec keeps the fd out of the test's own
      # subprocesses. Binary mode writes the JSON bytes as they are, so a
      # non-ASCII path is not rejected by an ASCII locale (#346).
      #
      # @api private
      # @return [String] Ruby script text.
      def result_channel_expression
        "_result = IO.new(#{RESULT_FD}, \"w\"); _result.binmode; _result.close_on_exec = true"
      end

      # Builds a pass/fail-only subprocess script (no coverage instrumentation).
      #
      # @api private
      # @param test_paths [Array<String>] test file paths.
      # @return [String] Ruby script text.
      def clean_check_script(test_paths)
        @framework == "rspec" ? rspec_clean_check_script(test_paths) : minitest_clean_check_script(test_paths)
      end

      # Minitest clean-suite check. Preloads configured sources and `--require`
      # files like capture and standalone {Runner.execute}, so tests that rely on
      # that preload stay green.
      #
      # @api private
      # @param test_paths [Array<String>] test file paths.
      # @return [String] Ruby script text.
      def minitest_clean_check_script(test_paths)
        <<~RUBY
          #{result_channel_expression}
          require "json"
          require #{FsPath::PATH.inspect}
          require "minitest"
          require "stringio"
          Mutineer::FsPath.install_minitest_path_filter!
          def Minitest.autorun; end
          _report = StringIO.new
          Minitest.define_singleton_method(:plugin_mutineer_report_init) { |options| reporter << Minitest::SummaryReporter.new(_report, options) }
          Minitest.extensions << "mutineer_report"
          $LOAD_PATH.unshift(*#{abs_load_paths.inspect})
          begin
            #{abs_preload_paths.map { |path| FsPath.filesystem(path) }.inspect}.each { |f| require f }
            Minitest::Runnable.reset
            #{minitest_file_order_setup(Array(test_paths).map { |t| FsPath.filesystem(absolute(t)).inspect }.join(", "))}
          #{load_failure_rescue}
          end
          _passed = Minitest.run(#{minitest_seed_args_expression})
          _failure = _passed ? nil : #{redacted_expression("_report.string")}
          _result.puts JSON.generate("passed" => _passed == true, "failure_report" => _failure)
          _result.close
          exit(_passed ? 0 : 1)
        RUBY
      end

      # RSpec clean-suite check. Preloads configured sources and `--require`
      # files like capture.
      #
      # @api private
      # @param test_paths [Array<String>] spec file paths.
      # @return [String] Ruby script text.
      def rspec_clean_check_script(test_paths)
        specs = Array(test_paths).map { |t| absolute(t).inspect }.join(", ")
        <<~RUBY
          #{result_channel_expression}
          require "json"
          require "stringio"
          begin
            require "rspec/core"
          rescue LoadError
            exit 3
          end
          RSpec::Core::Runner.disable_autorun!
          #{rspec_seed_install}
          $LOAD_PATH.unshift(*#{abs_load_paths.inspect})
          begin
            #{abs_preload_paths.inspect}.each { |f| require f }
          #{load_failure_rescue}
          end
          #{rspec_order_preamble(specs)}
          _sink = StringIO.new
          status = RSpec::Core::Runner.run(["--no-color", #{specs}], _sink, _sink)
          _failure = status.zero? ? nil : #{redacted_expression("_sink.string")}
          _result.puts JSON.generate("passed" => status.zero?, "failure_report" => _failure)
          _result.close
          exit(status.zero? ? 0 : 1)
        RUBY
      end

      # Ruby source, for a subprocess script, that loads the redaction module
      # and returns the redacted value of `expression`.
      #
      # @api private
      # @param expression [String] Ruby source for the text to redact.
      # @return [String] Ruby script text.
      def redacted_expression(expression)
        "(require #{REDACTION_PATH.inspect}; Mutineer::Redaction.text(#{expression}))"
      end

      # Ruby source, for a subprocess script, that closes a `begin` around the
      # project and test file loads. A load error then prints one redacted line
      # (Ruby's own printer would show DATABASE_URL raw), and the child still
      # exits 1, as it did when the error went uncaught. Under --verbose the
      # redacted backtrace follows; otherwise a hint says how to get it.
      #
      # @api private
      # @return [String] Ruby script text.
      def load_failure_rescue
        detail =
          if @verbose
            <<~RUBY.chomp
              (_e.backtrace || []).each { |_f| $stderr.puts("\t" + Mutineer::Redaction.text(_f)) }
              _cause = _e.cause
              while _cause
                $stderr.puts("[mutineer] caused by: " + Mutineer::Redaction.describe(_cause))
                _cause = _cause.cause
              end
            RUBY
          else
            '$stderr.puts("[mutineer] re-run with --verbose for the backtrace")'
          end
        <<~RUBY.chomp
          rescue ScriptError, StandardError => _e
            require #{REDACTION_PATH.inspect}
            $stderr.puts("[mutineer] load failed: " + Mutineer::Redaction.describe(_e))
            #{detail}
            exit 1
        RUBY
      end

      # Builds the framework-specific subprocess script.
      #
      # @api private
      # @param test_path [String] test file path.
      # @return [String] Ruby script text.
      def subprocess_script(test_path)
        @framework == "rspec" ? rspec_subprocess_script(test_path) : minitest_subprocess_script(test_path)
      end

      # Builds the minitest subprocess script.
      #
      # @api private
      # @param test_path [String] test file path.
      # @return [String] Ruby script text.
      def minitest_subprocess_script(test_path)
        <<~RUBY
          #{result_channel_expression}
          require "coverage"
          require "json"
          require #{FsPath::PATH.inspect}
          require "minitest"
          require "stringio"
          Mutineer::FsPath.install_minitest_path_filter!
          def Minitest.autorun; end
          _report = StringIO.new
          Minitest.define_singleton_method(:plugin_mutineer_report_init) { |options| reporter << Minitest::SummaryReporter.new(_report, options) }
          Minitest.extensions << "mutineer_report"
          Coverage.start(lines: true, methods: true)
          $LOAD_PATH.unshift(*#{abs_load_paths.inspect})
          begin
            #{abs_preload_paths.map { |path| FsPath.filesystem(path) }.inspect}.each { |f| require f }
            _load = #{load_coverage_expression}
            #{discard_load_counts_expression}
            Minitest::Runnable.reset
            #{minitest_file_order_setup(FsPath.filesystem(absolute(test_path)).inspect)}
          #{load_failure_rescue}
          end
          _passed = Minitest.run(#{minitest_seed_args_expression})
          _failure = _passed ? nil : #{redacted_expression("_report.string")}
          #{test_coverage_assignment}
          _result.puts JSON.generate("passed" => _passed == true, "coverage" => _coverage,
                                      "failure_report" => _failure,
                                      "load_coverage" => _load,
                                      "loaded_files" => #{loaded_files_expression})
          _result.close
        RUBY
      end

      # Selects the seed inside the generated child, after its tests and helpers
      # load. Choosing in the parent can ignore a helper's SEED assignment and
      # let a clean check pass in an order the mutant run never uses (#282).
      # The default comes from the same constant as the in-process runner; the
      # child needs no Mutineer require and the parent's environment is unchanged.
      #
      # @api private
      # @return [String] Ruby expression for the Minitest argument array.
      def minitest_seed_args_expression
        "ENV[\"SEED\"] ? [] : [\"--seed\", #{MinitestIntegration::PINNED_SEED.to_s.inspect}]"
      end

      # Same coverage-JSON contract as the minitest path, but driven by RSpec:
      # require rspec/core lazily, require the sources under Coverage, then run the
      # one spec via RSpec::Core::Runner. The JSON goes to the result channel (see
      # {#spawn_script}), so spec output cannot corrupt it. A missing rspec makes
      # the script exit non-zero -> capture() records a skipped (incomplete-map)
      # test, with a hint.
      def rspec_subprocess_script(test_path)
        <<~RUBY
          #{result_channel_expression}
          require "coverage"
          require "json"
          require #{FsPath::PATH.inspect}
          require "stringio"
          begin
            require "rspec/core"
          rescue LoadError
            warn "[mutineer] framework 'rspec' requested but rspec is not available in the project"
            exit 3
          end
          RSpec::Core::Runner.disable_autorun!
          #{rspec_seed_install}
          Coverage.start(lines: true, methods: true)
          $LOAD_PATH.unshift(*#{abs_load_paths.inspect})
          begin
            #{abs_preload_paths.inspect}.each { |f| require f }
            _load = #{load_coverage_expression}
            #{discard_load_counts_expression}
          #{load_failure_rescue}
          end
          #{rspec_order_preamble(absolute(test_path).inspect)}
          _sink = StringIO.new
          _status = RSpec::Core::Runner.run(["--no-color", #{absolute(test_path).inspect}], _sink, _sink)
          _failure = _status.zero? ? nil : #{redacted_expression("_sink.string")}
          #{test_coverage_assignment}
          _result.puts JSON.generate("passed" => _status.zero?, "coverage" => _coverage,
                                      "failure_report" => _failure,
                                      "load_coverage" => _load,
                                      "loaded_files" => #{loaded_files_expression})
          _result.close
        RUBY
      end
    end
  end
end
