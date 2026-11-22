# frozen_string_literal: true

module Mutineer
  class CoverageMap
    # Runs the unmutated tests (the clean check) and records a red result, a
    # timeout, or a failed capture to retry.
    #
    # These are private methods of {Mutineer::CoverageMap}. They read and write
    # its instance variables.
    #
    # @api private
    module CleanCheck
      private

      # Notes a red unmutated suite for {JobPlan.abort_if_unclean!} (issue #360).
      #
      # @api private
      # @param rel [String] project-relative test path, or `"combined suite"`.
      # @param detail [String, nil] failing test names / first error, capped.
      # @return [void]
      def record_failed_clean(rel, detail = nil)
        @failed_clean_tests << rel unless @failed_clean_tests.include?(rel)
        text = detail.to_s.strip
        return if text.empty?

        @failed_clean_details[rel] = truncate_clean_detail(text)
      end

      # Keeps the first failure block of a clean-failure report within
      # {CLEAN_FAILURE_DETAIL_LIMIT} characters. RSpec progress dots can fill
      # the head of the sink; prefer RSpec's `Failures:` / load-error header or
      # Minitest's numbered `N) Failure:` / `N) Error:` line. Do not match a bare
      # `Error:` — that cuts RSpec's `Failure/Error:` mid-token (#360).
      #
      # @api private
      # @param text [String] redacted reporter output.
      # @return [String]
      def truncate_clean_detail(text)
        starts = [text.index("Failures:")]
        # RSpec load errors and after(:suite)/after(:context) errors share this
        # header; do not require "while loading" or progress dots fill the cap.
        if (match = text.match(/^An error occurred /m))
          starts << match.begin(0)
        end
        if (match = text.match(/^\s*\d+\) (?:Failure|Error):/m))
          starts << match.begin(0)
        end
        start = starts.compact.min || 0
        report = start.zero? ? text : text[start..]
        return report if report.length <= CLEAN_FAILURE_DETAIL_LIMIT

        "#{report[0, CLEAN_FAILURE_DETAIL_LIMIT].rstrip}\n…"
      end

      # Re-runs each successfully captured test on a cache hit. Digest equality
      # cannot prove the current unmutated suite still passes.
      #
      # @api private
      # @param after_fork [Proc, nil] boot-mode fork hook.
      # @param test_paths [Array<String>] the tests to run, each alone.
      # @return [void]
      def verify_cached_clean(after_fork: nil, test_paths: @test_paths)
        test_paths.each do |test_path|
          rel = relativize(test_path)
          next if @failed_test_files.include?(rel)

          ok, detail, timed_out = timed_clean do
            if @boot_path
              fork_clean_pass?([absolute(test_path)], after_fork)
            else
              subprocess_clean_pass?([test_path])
            end
          end
          if timed_out
            record_clean_timeout(rel, @capture_timeout)
          elsif !ok
            record_failed_clean(rel, detail)
          end
        end
      end

      # Re-runs tests whose previous capture crashed. A fixed helper is invisible
      # to the source/test digest when that capture never recorded `loaded_files`.
      # A capture runs its test, so a red test lands in {#failed_clean_tests} here.
      #
      # @api private
      # @param after_fork [Proc, nil] boot-mode fork hook.
      # @return [Array<String>] the project-relative tests it captured again.
      def retry_failed_captures(after_fork)
        pending = @failed_test_files.dup
        return pending if pending.empty?

        @failed_test_files = []
        pending.each do |rel|
          test_path = @test_paths.find { |t| relativize(t) == rel } || rel
          capture_one(test_path, after_fork)
        end
        pending
      end

      # Captures one test file, standalone or by fork, and records the result.
      #
      # @api private
      # @param test_path [String] test file path.
      # @param after_fork [Proc, nil] boot-mode fork hook.
      # @return [void]
      def capture_one(test_path, after_fork)
        if @boot_path
          accept_fork_payload(test_path, timed(test_path) do
            fork_capture(absolute(test_path), abs_source_paths, after_fork)
          end)
        else
          payload = timed(test_path) { capture(test_path) }
          accept_capture_payload(test_path, payload) if payload
        end
      end

      # Runs one clean check and adds its wall-clock seconds to
      # {#clean_check_seconds} (#495).
      #
      # @api private
      # @yieldreturn [Array] the clean check's answer.
      # @return [Array] the block's value.
      def timed_clean
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        @clean_check_seconds = (@clean_check_seconds || 0.0) + (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      end

      # Runs every successfully captured test of {#clean_check_test_paths}
      # together. Per-file capture can miss a failure that only appears when
      # covering files share one process.
      #
      # @api private
      # @param after_fork [Proc, nil] boot-mode fork hook.
      # @return [void]
      def verify_combined_clean(after_fork: nil)
        runnable = clean_check_test_paths.reject { |t| @failed_test_files.include?(relativize(t)) }
        return if runnable.size < 2
        return unless @failed_clean_tests.empty?

        timeout = combined_clean_timeout(runnable)
        ok, detail, timed_out = timed_clean do
          if @boot_path
            fork_clean_pass?(runnable.map { |t| absolute(t) }, after_fork, timeout: timeout)
          else
            subprocess_clean_pass?(runnable, timeout: timeout)
          end
        end
        if timed_out
          record_clean_timeout("combined suite", timeout)
        elsif !ok
          record_failed_clean("combined suite", detail)
        end
      end

      # The combined clean check's deadline: {COMBINED_TIMEOUT_FACTOR} times the
      # summed capture seconds of `test_paths`, and at least `@capture_timeout`.
      # One process runs them all, so the per-file capture timeout alone stops a
      # green suite that is just slow.
      #
      # @api private
      # @param test_paths [Array<String>] the tests the combined check runs.
      # @return [Numeric] seconds.
      def combined_clean_timeout(test_paths)
        measured = test_paths.sum { |t| @timings[relativize(t)].to_f }
        [@capture_timeout, (measured * COMBINED_TIMEOUT_FACTOR).ceil].max
      end

      # Notes a clean check that hit its deadline. The run still stops, as for a
      # red suite, but the message says it timed out.
      #
      # @api private
      # @param rel [String] project-relative test path, or `"combined suite"`.
      # @param seconds [Numeric] the deadline that passed.
      # @return [void]
      def record_clean_timeout(rel, seconds)
        record_failed_clean(rel)
        @clean_timeouts[rel] = seconds
      end

      # Runs test files in a fresh interpreter and returns whether they passed.
      # The child writes a one-line JSON result with an optional failure report
      # (#360), so a leftover process cannot hold a stderr pipe open.
      #
      # @api private
      # @param test_paths [Array<String>] test file paths.
      # @param timeout [Numeric] seconds before the child is killed.
      # @return [Array(Boolean, String, Boolean)] pass flag, capped failure
      #   report, and whether the deadline passed.
      def subprocess_clean_pass?(test_paths, timeout: @capture_timeout)
        status, line = spawn_script(clean_check_script(test_paths), result: true, timeout: timeout)
        return [false, "", true] if status.nil?

        data = begin
          JSON.parse(line.to_s)
        rescue JSON::ParserError
          nil
        end
        # Fail closed: a child that exits 0 without a valid result line must not
        # clear the clean check (mutation honesty).
        return [false, "", false] unless data.is_a?(Hash)

        # Require the process exit too: an `at_exit` hook can fail after the
        # child already wrote `passed: true` (#360 warm-cache clean check).
        [status.success? && data["passed"] == true, data["failure_report"].to_s, false]
      end

      # Runs test files in a fork of the booted parent and returns whether they
      # passed, with a capped failure report for a red suite (#360).
      # Bounded by `timeout` so a hung child cannot block the CLI.
      #
      # @api private
      # @param abs_tests [Array<String>] absolute test file paths.
      # @param after_fork [Proc, nil] boot-mode fork hook.
      # @param timeout [Numeric] seconds before the child is killed.
      # @return [Array(Boolean, String, Boolean)] pass flag, failure report, and
      #   whether the deadline passed.
      def fork_clean_pass?(abs_tests, after_fork, timeout: @capture_timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        rd, wr = IO.pipe
        rd.binmode
        wr.binmode
        parent = Process.pid
        pid = fork do
          rd.close
          Process.setpgid(0, 0) rescue nil # rubocop:disable Style/RescueModifier
          OrphanGuard.start(parent)
          begin
            ChildStdout.silence
            after_fork&.call
            Coverage.result(clear: true, stop: false) if Coverage.running?
            passed, report = run_clean_with_report(abs_tests)
            wr.write(Marshal.dump([passed, report]))
          rescue Exception => e # rubocop:disable Lint/RescueException
            wr.write(Marshal.dump([false, Redaction.describe(e)]))
          ensure
            wr.close
            exit!(0)
          end
        end
        wr.close
        status, payload = await_child(pid, deadline) { read_marshal(rd) }
        return [false, "", true] if status.nil?
        return [false, "", false] unless payload.is_a?(Array)

        passed, report = payload
        [passed == true, report.to_s, false]
      rescue StandardError
        [false, "", false]
      ensure
        [rd, wr].compact.each { |io| io.close unless io.closed? }
      end

      # Runs tests in the current (forked) process and returns pass plus the
      # redacted reporter failure text when red (#360).
      #
      # @api private
      # @param abs_tests [Array<String>] absolute test file paths.
      # @return [Array(Boolean, String)]
      def run_clean_with_report(abs_tests)
        if @framework == "rspec"
          code = TestRunners.for(@framework).run(abs_tests)
          raw = TestRunners::RSpec.last_output.to_s
        else
          require "minitest"
          require "stringio"
          report = StringIO.new
          Minitest.define_singleton_method(:plugin_mutineer_clean_report_init) do |options|
            reporter << Minitest::SummaryReporter.new(report, options)
          end
          Minitest.extensions << "mutineer_clean_report" unless Minitest.extensions.include?("mutineer_clean_report")
          code = TestRunners.for(@framework).run(abs_tests)
          raw = report.string
        end
        # Forked children print this into SmokeCheckError; redact like the
        # subprocess JSON path so DATABASE_URL passwords never reach stderr.
        [code.zero?, code.zero? ? "" : Redaction.text(raw)]
      end

      # SIGKILLs capture child `pid` and its process group, then waits for
      # `waiter` to reap the child. Falls back to the pid alone when the group
      # does not exist yet.
      #
      # @api private
      # @param pid [Integer] child pid, also its process group id.
      # @param waiter [Thread] the Process.detach thread for `pid`.
      # @return [void]
      def kill_group(pid, waiter)
        begin
          Process.kill(:KILL, -pid)
        rescue Errno::ESRCH, Errno::EPERM
          # No group yet: the child has not run setpgid. Never signal a reaped pid.
          if waiter.alive?
            Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          end
        end
        waiter.join
      end
    end
  end
end
