# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "rbconfig"
require "coverage"
require "set"
require_relative "minitest_integration"
require_relative "test_runners"
require_relative "child_stdout"

module Mutineer
  # Maps `(source_file, line) -> [test_files]` so each mutant runs only against
  # the tests that actually exercise its line. Built once, then queried per
  # mutant via #tests_for. Persisted to .mutineer/coverage.json with a
  # content-based digest that rebuilds the map whenever any tracked file changes.
  #
  # Keys are "file:line" strings (relative to project_root) everywhere, in
  # memory and on disk, so load/save needs no key transformation.
  class CoverageMap
    # Seconds per coverage subprocess before the parent kills it.
    DEFAULT_CAPTURE_TIMEOUT = 120

    # File descriptor in a capture subprocess that carries the JSON result to
    # the parent. Stdout stays free for test output, which goes to File::NULL.
    RESULT_FD = 3

    attr_reader :project_root, :failed_test_files, :failed_clean_tests, :phase_a_ran, :map

    # Build a QUERY-ONLY map from data captured elsewhere (the daemon builds the
    # map app-side and ships `map` + `failed_test_files` over IPC; the tool
    # reconstructs it here for per-mutant selection). Skips the capture machinery
    # entirely: only the three fields #tests_for / #method_uncapturable? read are
    # set.
    #
    # @param map [Hash] the "file:line" => [test_files] map.
    # @param failed_test_files [Array<String>] test files whose capture failed.
    # @param project_root [String] project root (for path relativization).
    # @param failed_clean_tests [Array<String>] test files whose unmutated run failed.
    # @return [Mutineer::CoverageMap] a query-only map.
    def self.from_data(map:, failed_test_files:, project_root:, failed_clean_tests: [])
      instance = allocate
      instance.instance_variable_set(:@map, map || {})
      instance.instance_variable_set(:@failed_test_files, failed_test_files || [])
      instance.instance_variable_set(:@failed_clean_tests, failed_clean_tests || [])
      instance.instance_variable_set(:@project_root, project_root)
      instance
    end

    def initialize(source_paths:, test_paths:, cache_dir: ".mutineer",
                   load_paths: ["lib"], project_root: Dir.pwd,
                   capture_timeout: DEFAULT_CAPTURE_TIMEOUT, boot_path: nil,
                   framework: "minitest", verbose: false)
      @source_paths = Array(source_paths)
      @test_paths   = Array(test_paths)
      @cache_dir    = cache_dir
      @load_paths   = Array(load_paths)
      @project_root = project_root
      @capture_timeout = capture_timeout
      @boot_path    = boot_path
      @framework    = framework || "minitest"
      @verbose      = verbose
      @map          = {}
      @failed_test_files = []
      @failed_clean_tests = []
      @loaded_dependencies = {}
      @phase_a_ran  = false
    end

    # Standalone entry: load the cached map when the content digest matches,
    # otherwise rebuild from subprocesses and overwrite the cache.
    def build_or_load
      warn_external_sources
      cached_or { run_phase_a }
    end

    # Boot-mode build: Coverage is already running in the parent (started before
    # the app booted, so booted source lines are instrumented). A clean `ruby`
    # subprocess has no booted env, so per-test coverage is captured by FORKING
    # the booted parent instead. Inverts into the same map #tests_for reads, and
    # reuses the digest cache (the digest mixes in the boot file so a boot cache
    # never collides with a standalone one).
    def build_via_fork(after_fork: nil)
      warn_external_sources
      cached_or(after_fork: after_fork) { run_phase_a_via_fork(after_fork: after_fork) }
    end

    # Lookup: the test files that cover `file:line`, or [] when none do.
    # Per-file granularity; upgrade to per-method when throughput warrants
    # (requires Minitest method isolation + finer Coverage tracking).
    def tests_for(file, line)
      @map["#{relativize(file)}:#{line}"] || []
    end

    # Is this source file's empty coverage the result of an *errored* capture
    # rather than a genuine coverage gap? True iff some capture failed this run
    # AND this file got zero coverage from any successful capture AND a failed
    # test file maps to it by the standard _test/_spec naming convention. Derived
    # purely from already-persisted state (@map keys + @failed_test_files); no
    # rerun, no new cached field, no digest change.
    #
    # File-level, convention-based attribution. A line covered only by a failed
    # test in an otherwise-covered file stays no_coverage (condition 2), and a
    # source with no naming-convention test match is never tainted. Upgrade path:
    # persist per-file coverage per successful run and diff against the failed
    # set, or record test->source targets explicitly.
    def uncapturable_source?(file)
      return false if @failed_test_files.empty?

      rel = relativize(absolute(file))
      return false if covered_source_files.include?(rel)

      failed_test_targets.include?(File.basename(rel, ".rb"))
    end

    # Per-method taint. A mutant on a line whose enclosing method got zero
    # successful coverage, in a file a failed sibling test targets, is
    # :uncapturable (the capture that would have covered it errored), NOT a
    # genuine gap. A method with any covered line means its uncovered lines are a
    # real :no_coverage. A failed capture emits no coverage, so per-line intent is
    # unknowable; method-range + successful coverage is the finest derivable
    # signal. Fully-failed files behave exactly as uncapturable_source? did
    # (every method range has zero coverage).
    #
    # @param file [String] source file path.
    # @param line_range [Range] 1-based enclosing-method line range.
    # @return [Boolean]
    def method_uncapturable?(file, line_range)
      return false if @failed_test_files.empty?

      rel = relativize(absolute(file))
      return false unless failed_test_targets.include?(File.basename(rel, ".rb"))

      line_range.none? { |ln| @map.key?("#{rel}:#{ln}") }
    end

    private

    # Source rel-paths that received coverage from any successful capture.
    def covered_source_files
      @map.keys.map { |k| k.rpartition(":").first }.to_set
    end

    # Basenames of failed test files with a trailing _test/_spec (and .rb) stripped,
    # i.e. the source basenames they would have covered by convention.
    def failed_test_targets
      @failed_test_files.map { |t| File.basename(t, ".rb").sub(/_(test|spec)\z/, "") }.to_set
    end

    # Shared cache dance for both build paths: hit the digest-keyed cache, else
    # yield to populate @map and persist it. A digest match is not proof that
    # today's unmutated suite still passes — re-check on a cache hit.
    #
    # @param after_fork [Proc, nil] boot-mode fork hook forwarded to a clean re-check.
    # @yield when the cache is missing or stale.
    # @return [Mutineer::CoverageMap] self.
    def cached_or(after_fork: nil)
      @digest = compute_digest
      cached = read_cache
      if cached && cached["digest"] == @digest && dependencies_match?(cached)
        @map = cached["map"] || {}
        @failed_test_files = cached["failed_test_files"] || []
        @failed_clean_tests = []
        @loaded_dependencies = cached["dependencies"] || {}
        retry_failed_captures(after_fork)
        warn_incomplete unless @failed_test_files.empty?
        verify_cached_clean(after_fork: after_fork)
        verify_combined_clean(after_fork: after_fork)
        save
        return self
      end

      yield
      verify_combined_clean(after_fork: after_fork)
      save
      self
    end

    # Runs standalone coverage capture.
    #
    # @api private
    def run_phase_a
      @phase_a_ran = true
      @map = {}
      @failed_test_files = []
      @failed_clean_tests = []
      @loaded_dependencies = {}

      @test_paths.each do |test_path|
        payload = capture(test_path)
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
      @failed_test_files = []
      @failed_clean_tests = []
      @loaded_dependencies = {}
      abs_sources = abs_source_paths

      @test_paths.each do |test_path|
        # Tri-state payload: Hash = capture result, String = error diagnostic from
        # the child, nil = pipe gone / empty. The String diagnostic is what
        # becomes an :uncapturable status.
        case (payload = fork_capture(absolute(test_path), abs_sources, after_fork))
        when Hash then accept_capture_payload(test_path, payload)
        when String
          fail_test(test_path, @verbose ? "fork capture failed: #{payload}" :
            "fork capture produced no result (re-run with --verbose for the error)")
        else fail_test(test_path, "fork capture produced no result")
        end
      end
    end

    # Fork the booted parent, run one test under the inherited Coverage, and
    # return its per-source counts hash (or nil on failure). Reuses the same
    # fork + Marshal-over-pipe + hard-exit! discipline as WorkerPool/Isolation.
    def fork_capture(abs_test, abs_sources, after_fork)
      rd, wr = IO.pipe
      # Marshal output is binary: an un-binmoded pipe can raise
      # Encoding::UndefinedConversionError on write, which the child's rescue then
      # swallows, losing the real error and yielding a bare "no result".
      rd.binmode
      wr.binmode
      pid = fork do
        rd.close
        payload =
          begin
            ChildStdout.silence
            # Fork-safety hook: the in-process path reconnects AR; the daemon
            # routes to its worker DB. Nil (non-Rails) = no-op. Injected so this
            # file needs neither Runner (Prism) nor Rails.
            after_fork&.call
            Coverage.result(clear: true, stop: false) # discard pre-test delta
            passed = TestRunners.for(@framework).run([abs_test]).zero?
            # lines:true yields {file => {lines: [...]}}; reduce to the counts
            # array record() expects, keeping only our source files.
            coverage = Coverage.result(stop: false)
                               .select { |f, _| abs_sources.include?(f) }
                               .transform_values { |v| v.is_a?(Hash) ? v[:lines] : v }
            { "passed" => passed, "coverage" => coverage,
              "loaded_files" => capture_loaded_files }
          rescue Exception => e # rubocop:disable Lint/RescueException
            # Stringify (an arbitrary Exception may not marshal); the parent
            # surfaces this under --verbose. A String marshals safely over the pipe.
            "#{e.class}: #{e.message}#{e.backtrace&.first ? " @ #{e.backtrace.first}" : ''}"
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
      data = rd.read
      rd.close
      _, status = Process.waitpid2(pid)
      # An empty pipe means the child died before writing (e.g. a hard crash,
      # OOM, or a signal from the test's own subprocess handling). Report HOW it
      # died (exit status / signal) as a diagnostic string so --verbose has
      # something actionable instead of a silent "no result".
      return "child wrote no result (#{describe_status(status)})" if data.empty?

      Marshal.load(data)
    rescue StandardError => e
      "parent could not read capture result: #{e.class}: #{e.message}"
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
      warn "[mutineer] coverage skipped for #{rel}: #{reason}"
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

      unless payload["passed"]
        @failed_clean_tests << relativize(test_path)
        return
      end

      coverage = payload["coverage"]
      record(coverage, test_path) if coverage.is_a?(Hash)
    end

    # Re-runs each successfully captured test on a cache hit. Digest equality
    # cannot prove the current unmutated suite still passes.
    #
    # @api private
    # @param after_fork [Proc, nil] boot-mode fork hook.
    # @return [void]
    def verify_cached_clean(after_fork: nil)
      @test_paths.each do |test_path|
        rel = relativize(test_path)
        next if @failed_test_files.include?(rel)

        ok = if @boot_path
               fork_clean_pass?([absolute(test_path)], after_fork)
             else
               subprocess_clean_pass?([test_path])
             end
        @failed_clean_tests << rel unless ok
      end
    end

    # Re-runs tests whose previous capture crashed. A fixed helper is invisible
    # to the source/test digest when that capture never recorded `loaded_files`.
    #
    # @api private
    # @param after_fork [Proc, nil] boot-mode fork hook.
    # @return [void]
    def retry_failed_captures(after_fork)
      pending = @failed_test_files.dup
      return if pending.empty?

      @failed_test_files = []
      abs_sources = abs_source_paths
      pending.each do |rel|
        test_path = @test_paths.find { |t| relativize(t) == rel } || rel
        if @boot_path
          payload = fork_capture(absolute(test_path), abs_sources, after_fork)
          case payload
          when Hash then accept_capture_payload(test_path, payload)
          when String
            fail_test(test_path, @verbose ? "fork capture failed: #{payload}" :
              "fork capture produced no result (re-run with --verbose for the error)")
          else fail_test(test_path, "fork capture produced no result")
          end
        else
          payload = capture(test_path)
          accept_capture_payload(test_path, payload) if payload
        end
      end
    end

    # Runs every successfully captured test together. Per-file capture can miss a
    # failure that only appears when covering files share one process.
    #
    # @api private
    # @param after_fork [Proc, nil] boot-mode fork hook.
    # @return [void]
    def verify_combined_clean(after_fork: nil)
      runnable = @test_paths.reject { |t| @failed_test_files.include?(relativize(t)) }
      return if runnable.size < 2
      return unless @failed_clean_tests.empty?

      ok = if @boot_path
             fork_clean_pass?(runnable.map { |t| absolute(t) }, after_fork)
           else
             subprocess_clean_pass?(runnable)
           end
      @failed_clean_tests << "combined suite" unless ok
    end

    # Runs test files in a fresh interpreter and returns whether they passed.
    #
    # @api private
    # @param test_paths [Array<String>] test file paths.
    # @return [Boolean]
    def subprocess_clean_pass?(test_paths)
      status, = spawn_script(clean_check_script(test_paths), result: false)
      status&.success? || false
    end

    # Runs `script` in a fresh `ruby -` that reads the script from stdin. The
    # child's stdout goes to File::NULL, so test output never reaches the user
    # or the result. With `result: true`, the child writes its result as one
    # line to fd {RESULT_FD}, a pipe that only the script uses. The child's
    # stderr is the parent's stderr, so warnings from the script reach the
    # user. A wall clock of `@capture_timeout` bounds the whole call, so a hung
    # test cannot wedge the run.
    #
    # The parent reads one line, not until EOF: a process that a test leaves
    # running can inherit fd {RESULT_FD} (a `fork` without `exec` keeps it
    # despite close-on-exec) and hold the pipe open long after the child exits.
    # A clean check reports only through its exit status, so it gets no pipe.
    #
    # @api private
    # @param script [String] Ruby script text.
    # @param result [Boolean] whether to open the result pipe on fd {RESULT_FD}.
    # @return [Array(Process::Status, String)] the exit status and the line the
    #   child wrote to fd {RESULT_FD} (`""` without one); `[nil, ""]` after a
    #   timeout.
    def spawn_script(script, result: true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @capture_timeout
      script_rd, script_wr = IO.pipe
      result_rd, result_wr = IO.pipe if result
      options = { in: script_rd, out: File::NULL }
      options[RESULT_FD] = result_wr if result
      pid = Process.spawn(RbConfig.ruby, "-", **options)
      waiter = Process.detach(pid)
      script_rd.close
      result_wr&.close
      reader = Thread.new { result_rd.gets.to_s } if result
      script_wr.write(script)
      script_wr.close
      unless waiter.join(remaining(deadline))
        Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
        waiter.join
        reader&.kill
        return [nil, ""]
      end
      [waiter.value, reader&.join(remaining(deadline))&.value.to_s]
    ensure
      reader&.kill
      [script_rd, script_wr, result_rd, result_wr].compact.each { |io| io.close unless io.closed? }
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
    # subprocesses.
    #
    # @api private
    # @return [String] Ruby script text.
    def result_channel_expression
      "_result = IO.new(#{RESULT_FD}, \"w\"); _result.close_on_exec = true"
    end

    # Runs test files in a fork of the booted parent and returns whether they passed.
    # Bounded by `@capture_timeout` so a hung child cannot block the CLI.
    #
    # @api private
    # @param abs_tests [Array<String>] absolute test file paths.
    # @param after_fork [Proc, nil] boot-mode fork hook.
    # @return [Boolean]
    def fork_clean_pass?(abs_tests, after_fork)
      rd, wr = IO.pipe
      rd.binmode
      wr.binmode
      pid = fork do
        rd.close
        Process.setpgid(0, 0) rescue nil # rubocop:disable Style/RescueModifier
        begin
          ChildStdout.silence
          after_fork&.call
          Coverage.result(clear: true, stop: false) if Coverage.running?
          wr.write(Marshal.dump(TestRunners.for(@framework).run(abs_tests).zero?))
        rescue Exception # rubocop:disable Lint/RescueException
          wr.write(Marshal.dump(false))
        ensure
          wr.close
          exit!(0)
        end
      end
      wr.close
      readable, = IO.select([rd], nil, nil, @capture_timeout)
      unless readable
        kill_fork_clean(pid)
        rd.close
        return false
      end
      data = rd.read
      rd.close
      Process.waitpid2(pid)
      return false if data.empty?

      Marshal.load(data)
    rescue StandardError
      false
    end

    # SIGKILLs a hung clean-check child (and its group) then reaps it.
    #
    # @api private
    # @param pid [Integer] child pid.
    # @return [void]
    def kill_fork_clean(pid)
      begin
        Process.kill(:KILL, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
      end
      Process.waitpid2(pid) rescue nil # rubocop:disable Style/RescueModifier
    end

    # Builds a pass/fail-only subprocess script (no coverage instrumentation).
    #
    # @api private
    # @param test_paths [Array<String>] test file paths.
    # @return [String] Ruby script text.
    def clean_check_script(test_paths)
      @framework == "rspec" ? rspec_clean_check_script(test_paths) : minitest_clean_check_script(test_paths)
    end

    # Minitest clean-suite check. Preloads configured sources like capture and
    # standalone {Runner.execute}, so tests that rely on that preload stay green.
    #
    # @api private
    # @param test_paths [Array<String>] test file paths.
    # @return [String] Ruby script text.
    def minitest_clean_check_script(test_paths)
      loads = Array(test_paths).map { |t| "load #{absolute(t).inspect}" }.join("\n")
      <<~RUBY
        require "minitest"
        def Minitest.autorun; end
        $LOAD_PATH.unshift(*#{abs_load_paths.inspect})
        #{abs_source_paths.inspect}.each { |f| load f }
        #{loads}
        exit(Minitest.run([]) ? 0 : 1)
      RUBY
    end

    # RSpec clean-suite check. Preloads configured sources like capture.
    #
    # @api private
    # @param test_paths [Array<String>] spec file paths.
    # @return [String] Ruby script text.
    def rspec_clean_check_script(test_paths)
      specs = Array(test_paths).map { |t| absolute(t).inspect }.join(", ")
      <<~RUBY
        require "stringio"
        begin
          require "rspec/core"
        rescue LoadError
          exit 3
        end
        RSpec::Core::Runner.disable_autorun!
        $LOAD_PATH.unshift(*#{abs_load_paths.inspect})
        #{abs_source_paths.inspect}.each { |f| load f }
        _sink = StringIO.new
        status = RSpec::Core::Runner.run(["--no-color", #{specs}], _sink, _sink)
        exit(status.zero? ? 0 : 1)
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
        require "minitest"
        def Minitest.autorun; end
        Coverage.start(lines: true)
        $LOAD_PATH.unshift(*#{abs_load_paths.inspect})
        #{abs_source_paths.inspect}.each { |f| load f }
        load #{absolute(test_path).inspect}
        _passed = Minitest.run([])
        _result.puts JSON.generate("passed" => _passed == true, "coverage" => Coverage.result,
                                    "loaded_files" => #{loaded_files_expression})
        _result.close
      RUBY
    end

    # Same coverage-JSON contract as the minitest path, but driven by RSpec:
    # require rspec/core lazily, load the sources under Coverage, then run the
    # one spec via RSpec::Core::Runner. The JSON goes to the result channel (see
    # {#spawn_script}), so spec output cannot corrupt it. A missing rspec makes
    # the script exit non-zero -> capture() records a skipped (incomplete-map)
    # test, with a hint.
    def rspec_subprocess_script(test_path)
      <<~RUBY
        #{result_channel_expression}
        require "coverage"
        require "json"
        require "stringio"
        begin
          require "rspec/core"
        rescue LoadError
          warn "[mutineer] framework 'rspec' requested but rspec is not available in the project"
          exit 3
        end
        RSpec::Core::Runner.disable_autorun!
        Coverage.start(lines: true)
        $LOAD_PATH.unshift(*#{abs_load_paths.inspect})
        #{abs_source_paths.inspect}.each { |f| load f }
        _sink = StringIO.new
        _status = RSpec::Core::Runner.run(["--no-color", #{absolute(test_path).inspect}], _sink, _sink)
        _result.puts JSON.generate("passed" => _status.zero?, "coverage" => Coverage.result,
                                    "loaded_files" => #{loaded_files_expression})
        _result.close
      RUBY
    end

    # Records every source line with a non-zero execution count as covered by
    # this test file. Coverage.result keys are absolute; relativize and drop any
    # path outside the project (stdlib/gem files).
    def record(coverage, test_path)
      rel_test = relativize(test_path)
      coverage.each do |abs_file, data|
        rel = relativize(abs_file)
        next if rel.start_with?("/") # outside project_root: not our source

        counts = data.is_a?(Array) ? data : data["lines"]
        counts.each_with_index do |count, idx|
          next unless count&.positive?

          (@map["#{rel}:#{idx + 1}"] ||= []) << rel_test
        end
      end
    end

    # Ruby source of the child-side `$LOADED_FEATURES` filter (project `.rb` files).
    #
    # @api private
    # @return [String] expression to embed in a capture subprocess script.
    def loaded_files_expression
      root = project_root_real
      prefix = root.end_with?("/") ? root : "#{root}/"
      "begin; _root = #{prefix.inspect}; $LOADED_FEATURES.filter_map { |f| next unless f.end_with?(\".rb\"); abs = (File.realpath(f) rescue next); abs if abs.start_with?(_root) }; rescue StandardError; []; end"
    end

    # Canonical project root for loaded-feature matching (`/var` vs `/private/var`).
    #
    # @api private
    # @return [String] realpath of the project root when it exists.
    def project_root_real
      File.realpath(File.expand_path(@project_root))
    rescue Errno::ENOENT
      File.expand_path(@project_root)
    end

    # Project-local `.rb` files loaded in this process at capture time.
    #
    # @api private
    # @return [Array<String>] absolute realpaths.
    def capture_loaded_files
      prefix = project_root_real
      prefix = "#{prefix}/" unless prefix.end_with?("/")
      $LOADED_FEATURES.filter_map do |f|
        next unless f.end_with?(".rb")

        abs = File.realpath(f)
        abs if abs.start_with?(prefix)
      rescue Errno::ENOENT
        nil
      end
    end

    # Fingerprints project-local support files from a capture payload.
    #
    # @api private
    # @param paths [Array, nil] absolute loaded-file paths.
    # @return [void]
    def record_loaded(paths)
      Array(paths).each do |raw|
        next unless raw.is_a?(String) && File.file?(raw)

        abs = File.realpath(raw)
        rel = loaded_relative(abs)
        next unless rel
        next unless rel.end_with?(".rb")
        next if rel.start_with?("vendor/bundle/") || rel.start_with?("node_modules/")

        @loaded_dependencies[rel] = file_fingerprint(abs)
      end
    end

    # Path of `abs` relative to the real project root, or nil when outside it.
    #
    # @api private
    # @param abs [String] absolute realpath.
    # @return [String, nil]
    def loaded_relative(abs)
      root = project_root_real
      prefix = root.end_with?("/") ? root : "#{root}/"
      return unless abs.start_with?(prefix)

      abs.delete_prefix(prefix)
    end

    # Byte fingerprint of a file for cache dependency checks.
    #
    # @api private
    # @param abs [String] absolute path.
    # @return [String] hex digest.
    def file_fingerprint(abs)
      content = File.binread(abs)
      Digest::SHA256.hexdigest("#{content.bytesize}\0#{content}")
    end

    # True when the cached map recorded support-file fingerprints and they still
    # match. Missing validity data is a miss (rebuild).
    #
    # @api private
    # @param cached [Hash] parsed coverage.json.
    # @return [Boolean]
    def dependencies_match?(cached)
      deps = cached["dependencies"]
      return false unless deps.is_a?(Hash)

      deps.all? do |rel, fingerprint|
        abs = absolute(rel)
        File.file?(abs) && file_fingerprint(abs) == fingerprint
      end
    end

    # Digest each file's ROLE + relative path + content length + content, plus
    # the load_paths. Without role/path/length delimiters the digest collides
    # (("ab","c") == ("a","bc")) and is blind to source/test role swaps, silently
    # accepting a stale cached map.
    def compute_digest
      d = Digest::SHA256.new
      digest_group(d, "source", @source_paths)
      digest_group(d, "test", @test_paths)
      digest_group(d, "boot", [boot_digest_path]) if @boot_path
      @load_paths.sort.each { |lp| d.update("loadpath\0#{lp}\0") }
      d.update("framework\0#{@framework}\0")
      d.hexdigest
    end

    # boot_path is a require-style path (e.g. "config/environment", no extension);
    # resolve it to the real file for reading, appending ".rb" when needed.
    def boot_digest_path
      File.exist?(absolute(@boot_path)) ? @boot_path : "#{@boot_path}.rb"
    end

    # Groups a digest with its role and paths.
    #
    # @api private
    # @param digest [String] digest string.
    # @param role [String] digest role.
    # @param paths [Array<String>] paths in the digest group.
    # @return [Array(String, String, Array<String>)] grouped digest data.
    def digest_group(digest, role, paths)
      paths.sort.each do |p|
        content = File.read(absolute(p))
        digest.update(role)
        digest.update("\0")
        digest.update(relativize(absolute(p)))
        digest.update("\0")
        digest.update(content.bytesize.to_s)
        digest.update("\0")
        digest.update(content)
        digest.update("\0")
      end
    end

    # A configured source that resolves outside project_root would silently be
    # dropped (its coverage relativizes to an absolute path). Warn instead.
    def warn_external_sources
      @source_paths.each do |p|
        next unless relativize(absolute(p)).start_with?("/")

        warn "[mutineer] source #{p} is outside project root #{@project_root}; " \
             "its coverage will be ignored"
      end
    end

    # Returns the cache path.
    #
    # @api private
    # @return [String] cache file path.
    def cache_path = File.join(@cache_dir, "coverage.json")

    # Reads the coverage cache.
    #
    # @api private
    # @return [Hash, nil] cached payload.
    def read_cache
      return nil unless File.exist?(cache_path)

      JSON.parse(File.read(cache_path))
    rescue JSON::ParserError
      nil # corrupt cache: rebuild from scratch
    end

    # Saves the coverage cache.
    #
    # @api private
    # @return [void]
    def save
      return unless @failed_clean_tests.empty?

      FileUtils.mkdir_p(@cache_dir)
      data = { "digest" => @digest, "failed_test_files" => @failed_test_files,
               "dependencies" => @loaded_dependencies, "map" => @map }
      tmp = "#{cache_path}.tmp"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, cache_path) # atomic swap
    end

    # Warns when coverage capture was incomplete.
    #
    # @api private
    # @return [void]
    def warn_incomplete
      warn "[mutineer] cached coverage map may be incomplete; these test files " \
           "failed to contribute: #{@failed_test_files.join(', ')}"
    end

    # Returns absolute source paths.
    #
    # @return [Array<String>] absolute source paths.
    def abs_source_paths = @source_paths.map { |p| absolute(p) }

    # Returns absolute load paths.
    #
    # @return [Array<String>] absolute load paths.
    def abs_load_paths   = @load_paths.map { |p| absolute(p) }

    # Relativizes a path against the project root.
    #
    # @api private
    # @param path [String] path to relativize.
    # @return [String] relative path.
    def relativize(path)
      abs = path.start_with?("/") ? path : absolute(path)
      abs = realpath_if_exists(abs)
      root = project_root_real
      prefix = root.end_with?("/") ? root : "#{root}/"
      return abs unless abs.start_with?(prefix)

      abs.delete_prefix(prefix)
    end

    # Expands a path relative to the project root.
    #
    # @api private
    # @param path [String] path to expand.
    # @return [String] absolute path.
    def absolute(path)
      raw = File.absolute_path?(path) ? path : File.expand_path(path, @project_root)
      realpath_if_exists(raw)
    end

    # Real path when the file exists, otherwise `path` unchanged.
    #
    # @api private
    # @param path [String] absolute or relative path.
    # @return [String]
    def realpath_if_exists(path)
      File.exist?(path) ? File.realpath(path) : path
    end
  end
end
