# frozen_string_literal: true

module Mutineer
  class CoverageMap
    # Captures per-test coverage, in a child Ruby or in a fork of the booted
    # parent, and accepts each child's payload into the map.
    #
    # These are private methods of {Mutineer::CoverageMap}. They read and write
    # its instance variables.
    #
    # @api private
    module Capture
      private

      # Runs standalone coverage capture.
      #
      # @api private
      def run_phase_a
        @phase_a_ran = true
        @map = {}
        @load_lines = Set.new
        @load_methods = Set.new
        @timings = {}
        @failed_test_files = []
        @failed_clean_tests = []
        @failed_clean_details = {}
        @clean_timeouts = {}
        @clean_check_seconds = nil
        @loaded_dependencies = {}
        @paired_in_run = nil

        @test_paths.each do |test_path|
          payload = timed(test_path) { capture(test_path) }
          next unless payload

          accept_capture_payload(test_path, payload)
        end
      end

      # Boot-mode capture. For each test file, fork the booted parent; the child
      # resets its Coverage delta, runs that ONE test, and marshals back the raw
      # per-source coverage counts. record() inverts them exactly as the subprocess
      # path does. Serial fork (one test at a time): boot apps fork cheaply via COW
      # and per-test isolation matters more than throughput here.
      def run_phase_a_via_fork(after_fork:)
        @phase_a_ran = true
        @map = {}
        @timings = {}
        @failed_test_files = []
        @failed_clean_tests = []
        @failed_clean_details = {}
        @clean_timeouts = {}
        @clean_check_seconds = nil
        @loaded_dependencies = {}
        abs_sources = abs_source_paths

        @test_paths.each do |test_path|
          accept_fork_payload(test_path, timed(test_path) { fork_capture(absolute(test_path), abs_sources, after_fork) })
        end
      end

      # Runs the block, a capture of `test_path`, and records its wall-clock
      # seconds in {#timings}. The parent times the whole capture, so the
      # numbers compare files, not exact test cost.
      #
      # @api private
      # @param test_path [String] test file path.
      # @yieldreturn [Object] the capture result.
      # @return [Object] the block's value.
      def timed(test_path)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        value = yield
        @timings[relativize(test_path)] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
        value
      end

      # Records a {#fork_capture} result. Hash = capture result, String = error
      # diagnostic from the child, :timeout = the capture deadline passed, nil =
      # pipe gone / empty. The String diagnostic is what becomes an
      # :uncapturable status. It is printed with or without `--verbose` (#537):
      # one line without it, the full message and the first frame with it.
      #
      # @api private
      # @param test_path [String] test file path.
      # @param payload [Hash, String, Symbol, nil] what {#fork_capture} returned.
      # @return [void]
      def accept_fork_payload(test_path, payload)
        case payload
        when Hash then accept_capture_payload(test_path, payload)
        when :timeout then fail_test(test_path, "timed out after #{@capture_timeout}s")
        when String then fail_test(test_path, "fork capture failed: #{payload}")
        else fail_test(test_path, "fork capture produced no result")
        end
      end

      # Fork the booted parent, run one test under the inherited Coverage, and
      # return the child's wrapped payload (`passed`, `coverage`, `failure_report`,
      # `loaded_files`, read by `accept_fork_payload`), a String diagnostic on failure, or
      # :timeout after `@capture_timeout` (see {#await_child}). Reuses the same
      # fork + Marshal-over-pipe + hard-exit! discipline as WorkerPool/Isolation.
      def fork_capture(abs_test, abs_sources, after_fork)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @capture_timeout
        rd, wr = IO.pipe
        # Marshal output is binary: an un-binmoded pipe can raise
        # Encoding::UndefinedConversionError on write, which the child's rescue then
        # swallows, losing the real error and yielding a bare "no result".
        rd.binmode
        wr.binmode
        parent = Process.pid
        pid = fork do
          rd.close
          Process.setpgid(0, 0) rescue nil # rubocop:disable Style/RescueModifier
          OrphanGuard.start(parent)
          payload =
            begin
              ChildStdout.silence
              # Fork-safety hook: the in-process path reconnects AR; the daemon
              # drops its protocol channel and routes to its worker DB. Nil =
              # no-op. Injected so this file needs neither Runner (Prism) nor Rails.
              after_fork&.call
              Coverage.result(clear: true, stop: false) # discard pre-test delta
              passed, report = run_clean_with_report([abs_test])
              # {file => {lines: [...], methods: {...}}}; reduce to the counts
              # array record() expects, keeping only our source files.
              wanted = abs_sources.map { |path| FsPath.read(path) }
              # Coverage keys are US-ASCII with invalid bytes under LC_ALL=C (#346).
              coverage = Coverage.result(stop: false)
                                 .to_h { |f, v| [FsPath.read(f), v] }
                                 .select { |f, _| wanted.include?(f) }
                                 .transform_values { |v| v.is_a?(Hash) ? lines_with_called_defs(v) : v }
              { "passed" => passed, "coverage" => coverage,
                "failure_report" => passed ? nil : report,
                "loaded_files" => capture_loaded_files }
            rescue Exception => e # rubocop:disable Lint/RescueException
              # Stringify (an arbitrary Exception may not marshal); a String
              # marshals safely over the pipe. Without --verbose it is one
              # redacted, cut line (#537); with it, the full message and the
              # first frame. A value, not a `return`: a `return` here raises in
              # the fork block, and the child then sends no payload.
              if @verbose
                "#{e.class}: #{e.message}#{e.backtrace&.first ? " @ #{e.backtrace.first}" : ''}"
              else
                ChildCause.line(e)
              end
            end
          begin
            wr.write(Marshal.dump(payload))
          rescue StandardError # rubocop:disable Lint/SuppressedException
            # pipe gone; parent records "no result"
          ensure
            wr.close
            exit!(0) # skip at_exit so the parent suite's autorun never re-fires here
          end
        end
        wr.close
        # Marshal.load reads exactly one object, not until EOF: a process that the
        # test leaves running (even outside the group) can hold the pipe open.
        status, payload = await_child(pid, deadline) { read_marshal(rd) }
        return :timeout unless status

        # An empty pipe means the child died before writing (e.g. a hard crash,
        # OOM, or a signal from the test's own subprocess handling). Report HOW it
        # died (exit status / signal) as a diagnostic string so --verbose has
        # something actionable instead of a silent "no result".
        return "child wrote no result (#{describe_status(status)})" if payload.nil?

        payload
      rescue StandardError => e
        "parent could not read capture result: #{e.class}: #{e.message}"
      ensure
        [rd, wr].compact.each { |io| io.close unless io.closed? }
      end

      # Human description of a child Process::Status for capture diagnostics.
      #
      # @api private
      # @param status [Process::Status] the reaped child status.
      # @return [String] e.g. "killed by signal 9 (SIGKILL)" or "exit status 1".
      def describe_status(status)
        if status.signaled?
          sig = status.termsig
          "killed by signal #{sig}#{Signal.signame(sig) ? " (SIG#{Signal.signame(sig)})" : ''}"
        else
          "exit status #{status.exitstatus.inspect}"
        end
      end

      # Spawns a fresh `ruby` reading an inline script from stdin. A fork would
      # miss already-loaded app lines, so Coverage must start in a clean process
      # before any source is loaded. Returns the wrapped capture payload
      # (`passed` + `coverage`), or nil when the subprocess failed (logged + skipped).
      def capture(test_path)
        status, out = spawn_script(subprocess_script(test_path))
        return fail_test(test_path, "timed out after #{@capture_timeout}s") unless status
        return fail_test(test_path, "subprocess exited #{status.exitstatus}") unless status.success?

        parsed = JSON.parse(out)
        return fail_test(test_path, "invalid coverage output: missing pass/coverage payload") unless wrapped_capture?(parsed)

        parsed
      rescue JSON::ParserError => e
        fail_test(test_path, "invalid coverage output: #{e.message}")
      end

      # Records a failed coverage capture.
      #
      # @api private
      # @param test_path [String] test file path.
      # @param reason [String] failure reason.
      # @return [void]
      def fail_test(test_path, reason)
        rel = relativize(test_path)
        @failed_test_files << rel
        # The reason can quote an app error, and so a credentialed DATABASE_URL.
        # DaemonClient::COVERAGE_SKIPPED matches this prefix to add its load
        # note under --daemon (#517): keep the two in step.
        warn "[mutineer] coverage skipped for #{rel}: #{Redaction.text(reason)}"
        nil
      end

      # True when `payload` is the wrapped capture JSON/Marshal contract
      # (`passed` + `coverage`), not a raw Coverage.result hash.
      #
      # @api private
      # @param payload [Object] parsed subprocess output or forked Marshal value.
      # @return [Boolean]
      def wrapped_capture?(payload)
        payload.is_a?(Hash) && payload.key?("passed") && payload.key?("coverage")
      end

      # Records a wrapped capture: assertion failures go to {#failed_clean_tests};
      # successful coverage is inverted into the map. Capture crashes stay in
      # {#failed_test_files} via {#fail_test}.
      #
      # @api private
      # @param test_path [String] test file path.
      # @param payload [Hash] wrapped capture with string keys.
      # @return [void]
      def accept_capture_payload(test_path, payload)
        unless wrapped_capture?(payload)
          fail_test(test_path, "invalid coverage output: missing pass/coverage payload")
          return
        end

        record_loaded(payload["loaded_files"])
        record_load(payload["load_coverage"])

        unless payload["passed"]
          record_failed_clean(relativize(test_path), payload["failure_report"])
          return
        end

        coverage = payload["coverage"]
        return unless coverage.is_a?(Hash)

        # Post-load counts only. Standalone capture clears the load snapshot
        # before the test runs; a fork capture already discarded the boot delta.
        record(map_coverage(coverage), test_path)
        # Lines that ran only while the sources loaded. The paired test keeps
        # them, so a reload mutant a test checks through a value built at load
        # still runs (#348). An unrelated test does not.
        record_paired_load_lines(payload["load_coverage"], coverage, test_path)
      end
    end
  end
end
