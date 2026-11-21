# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "rbconfig"
require "coverage"
require "prism"
require "set"
require_relative "minitest_integration"
require_relative "test_runners"
require_relative "child_stdout"
require_relative "orphan_guard"
require_relative "redaction"
require_relative "project_path"
require_relative "pairing"
require_relative "coverage_map/failed_test_blame"
require_relative "coverage_map/capture_reuse"
require_relative "coverage_map/capture"

module Mutineer
  # A `--coverage-from` capture that cannot be read, or does not fit this run.
  class CoverageFromError < StandardError; end

  # Maps `(source_file, line) -> [test_files]` so each mutant runs only against
  # the tests that actually exercise its line. Built once, then queried per
  # mutant via #tests_for. Persisted to .mutineer/coverage.json with a
  # content-based digest. A later run recaptures every test when a run input,
  # a loaded file, or the shape of a source changes. A change that stays inside
  # method bodies, without moving a line or editing a method that ran at load,
  # recaptures only the tests in that source's map entries (#421).
  #
  # Keys are "file:line" strings (relative to project_root) everywhere, in
  # memory and on disk, so load/save needs no key transformation.
  class CoverageMap
    include FailedTestBlame
    include CaptureReuse
    include Capture

    # Seconds per coverage subprocess before the parent kills it.
    DEFAULT_CAPTURE_TIMEOUT = 120

    # The combined clean check runs the clean-check test files in one process.
    # Its deadline is this factor times the summed capture seconds of those
    # files, and never less than the capture timeout.
    COMBINED_TIMEOUT_FACTOR = 1.5

    # File descriptor in a capture subprocess that carries the JSON result to
    # the parent. Stdout stays free for test output, which goes to File::NULL.
    RESULT_FD = 3

    # Seconds a capture waits for its result after the child exits in time.
    # The result is already in the pipe then; the wait only lets the reader
    # thread run, even when the capture deadline has passed (#129).
    RESULT_GRACE = 1
    # The redaction module, by absolute path, for the subprocess scripts: they
    # write a failing test's report, or a load error, to the inherited stderr,
    # and either can quote DATABASE_URL.
    REDACTION_PATH = File.expand_path("redaction.rb", __dir__)

    # Cap for a failing clean-suite report on the SmokeCheckError line (#360).
    CLEAN_FAILURE_DETAIL_LIMIT = 800

    # Key in coverage.json that marks a map built after #426. Standalone
    # capture no longer credits every test with lines that ran only while the
    # sources loaded. A standalone cache without this key was built the old
    # way and is rebuilt once. Boot and daemon maps already omitted those
    # lines; a hit there does not read the key.
    NARROW_LOAD_LINES = "narrow_load_lines"

    # Keys a cache needs before a method-body edit can recapture part of the
    # map (#421). A cache saved before these keys existed is rebuilt once.
    PARTIAL_CACHE_KEYS = %w[run_inputs sources skeletons tests load_method_bodies].freeze

    # Key for the paired tests that kept load-only lines when the map was
    # saved. {Pairing.infer_tests} reads files that are not in this run. An
    # exact spec replaces split tests, and the content digest does not see a
    # file the run did not select. A standalone hit rebuilds when this list
    # no longer matches.
    LOAD_LINE_PAIRS = "load_line_pairs"

    attr_reader :project_root, :failed_test_files, :failed_clean_tests, :failed_clean_details,
                :phase_a_ran, :map

    # Clean checks that hit their deadline, keyed like {#failed_clean_tests},
    # with the deadline in seconds. Each key is also in {#failed_clean_tests},
    # so the run still stops, but {JobPlan.abort_if_unclean!} reports a
    # timeout, not a red suite.
    #
    # @return [Hash{String => Numeric}]
    attr_reader :clean_timeouts

    # The source lines that ran while the app booted or the sources and the
    # `--require` files loaded, before any test ran, as a Set of "file:line"
    # keys like {#map}'s (#187, #217).
    # A mutant on such a line can change a value computed before the mutant was
    # applied, so its verdict is not trusted (`ran_at_load`).
    #
    # @return [Set<String>]
    attr_reader :load_lines

    # The source methods that were called while the app booted or the sources
    # and the `--require` files loaded, as a Set of "file:line:column" keys of
    # their `def` (#209). Line coverage cannot tell this for a one-line or
    # endless method: its `def` line counts when the method is defined.
    #
    # @return [Set<String>]
    attr_reader :load_methods

    # Seconds each test file took to capture, keyed by project-relative path
    # (#203). {#order_tests} runs the cheaper files first.
    #
    # @return [Hash{String => Float}]
    attr_reader :timings

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
    # @param failed_clean_details [Hash{String => String}] capped failure report per
    #   failed clean test (issue #360).
    # @param load_lines [Array<String>, Set<String>] "file:line" keys that ran at load ({#load_lines}).
    # @param load_methods [Array<String>, Set<String>] "file:line:column" keys of methods called at load
    #   ({#load_methods}).
    # @param timings [Hash{String => Float}] capture seconds per test file ({#timings}).
    # @param clean_timeouts [Hash{String => Numeric}] clean checks that timed out ({#clean_timeouts}).
    # @return [Mutineer::CoverageMap] a query-only map.
    def self.from_data(map:, failed_test_files:, project_root:, failed_clean_tests: [],
                       failed_clean_details: {}, load_lines: [],
                       load_methods: [], timings: {}, clean_timeouts: {})
      instance = allocate
      instance.instance_variable_set(:@map, map || {})
      instance.instance_variable_set(:@timings, timings || {})
      instance.instance_variable_set(:@load_lines, Set.new(load_lines || []))
      instance.instance_variable_set(:@load_methods, Set.new(load_methods || []))
      instance.instance_variable_set(:@failed_test_files, failed_test_files || [])
      instance.instance_variable_set(:@failed_clean_tests, failed_clean_tests || [])
      instance.instance_variable_set(:@failed_clean_details, failed_clean_details || {})
      instance.instance_variable_set(:@clean_timeouts, clean_timeouts || {})
      instance.instance_variable_set(:@project_root, FsPath.read(project_root))
      instance
    end

    def initialize(source_paths:, test_paths:, cache_dir: ".mutineer",
                   load_paths: ["lib"], project_root: Dir.pwd,
                   capture_timeout: DEFAULT_CAPTURE_TIMEOUT, boot_path: nil,
                   framework: "minitest", verbose: false, require_paths: [], coverage_from: nil)
      @source_paths = Array(source_paths).map { |path| FsPath.read(path) }
      @require_paths = Array(require_paths).map { |path| FsPath.read(path) }
      @test_paths   = Array(test_paths).map { |path| FsPath.read(path) }
      @cache_dir    = FsPath.read(cache_dir)
      @coverage_from = coverage_from && FsPath.read(coverage_from)
      @load_paths   = Array(load_paths).map { |path| FsPath.read(path) }
      @project_root = FsPath.read(project_root)
      @capture_timeout = capture_timeout
      @boot_path    = boot_path
      @framework    = framework || "minitest"
      @verbose      = verbose
      @map          = {}
      @failed_test_files = []
      @failed_clean_tests = []
      @failed_clean_details = {}
      @clean_timeouts = {}
      @load_lines   = Set.new
      @load_methods = Set.new
      @timings      = {}
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
    #
    # The lines that ran during boot are read here on every run, cache or not:
    # the boot runs every time, and no test is credited with those lines.
    def build_via_fork(after_fork: nil)
      warn_external_sources
      # Matched by real path in #record_load: a Coverage key is the path as
      # required, which can differ from the configured one (/var, /private/var).
      booted = Coverage.running? ? Coverage.peek_result : {}
      record_load(booted.transform_values { |v| v.is_a?(Hash) ? load_entry(v[:lines], v[:methods]) : v })
      cached_or(after_fork: after_fork) { run_phase_a_via_fork(after_fork: after_fork) }
    end

    # Lookup: the test files that cover `file:line`, or [] when none do.
    # Per-file granularity; upgrade to per-method when throughput warrants
    # (requires Minitest method isolation + finer Coverage tracking).
    def tests_for(file, line)
      @map["#{relativize(file)}:#{line}"] || []
    end

    # The covering `tests` of a mutant in `file`, in the order a mutant run
    # loads them (#203): the files {Pairing.infer_tests} pairs with `file`
    # first, then the cheapest by {#timings}. A file with no timing comes
    # after the timed ones, and the path breaks a tie, so the same cache gives
    # the same order on every run. Costs compare in doubling buckets
    # (`log2(seconds - fastest + 1)`), so files of close cost keep their path
    # order when a rebuild measures them again. Taking off the fastest
    # captured file's time removes the startup cost every standalone capture
    # pays; a failed capture is timed again on each run, so it does not count.
    # A run that stops at the first failure then reaches a fast killing test
    # before a slow file uses up the timeout.
    #
    # @param file [String] the mutated source file path.
    # @param tests [Array<String>] project-relative test paths from {#tests_for}.
    # @return [Array<String>] the same paths, reordered.
    def order_tests(file, tests)
      rel = relativize(absolute(file))
      @paired ||= {}
      paired = @paired[rel] ||= Pairing.infer_tests(rel, project_root: @project_root,
                                                         prefer: @framework || "minitest")
      base = @timings.except(*@failed_test_files).values.min || 0
      tests.sort_by do |t|
        cost = @timings[t]
        [paired.include?(t) ? 0 : 1, cost ? Math.log2(cost - base + 1).floor : Float::INFINITY, t]
      end
    end

    # True when `file:line` ran while the app booted or the sources loaded
    # (see {#load_lines}).
    #
    # @param file [String] source file path.
    # @param line [Integer] 1-based line.
    # @return [Boolean]
    def ran_at_load?(file, line)
      @load_lines.include?("#{relativize(file)}:#{line}")
    end

    # True when the method whose `def` starts at `line` and `column` of `file`
    # was called while the app booted or the sources loaded (see {#load_methods}).
    #
    # @param file [String] source file path.
    # @param line [Integer] 1-based line of the `def`.
    # @param column [Integer] 0-based byte column of the `def`.
    # @return [Boolean]
    def method_ran_at_load?(file, line, column)
      @load_methods.include?("#{relativize(file)}:#{line}:#{column}")
    end

    # Is this source file's empty coverage the result of an *errored* capture
    # rather than a genuine coverage gap? True iff some capture failed this run
    # AND this file got zero coverage from any successful capture AND a failed
    # test file maps to it by the _test/_spec/test_ naming convention. Derived
    # from already-persisted state (@map keys + @failed_test_files). A split
    # name checks the longer source files that existed when that check first
    # ran for this map. Adding or deleting one of those files changes the
    # coverage digest, so the next run captures again instead of retargeting
    # a stored failure.
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

      failed_test_blames?(rel)
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
      return false unless failed_test_blames?(rel)

      line_range.none? { |ln| @map.key?("#{rel}:#{ln}") }
    end

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

        ok, detail, timed_out = if @boot_path
                                  fork_clean_pass?([absolute(test_path)], after_fork)
                                else
                                  subprocess_clean_pass?([test_path])
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
      ok, detail, timed_out = if @boot_path
                                fork_clean_pass?(runnable.map { |t| absolute(t) }, after_fork, timeout: timeout)
                              else
                                subprocess_clean_pass?(runnable, timeout: timeout)
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

    # Loads the test files and installs {MinitestIntegration::FileOrder} so the
    # subprocess clean check and coverage capture shuffle each file the same
    # way as {MinitestIntegration.run} (#282). The child requires only the
    # file-order file, not the rest of the runner.
    #
    # @api private
    # @param files_list_source [String] Ruby source for the path arguments,
    #   one inspected string or several joined by commas.
    # @return [String] Ruby script text.
    def minitest_file_order_setup(files_list_source)
      path = File.expand_path("minitest_integration/file_order.rb", __dir__)
      <<~RUBY.chomp
        _rank = {}
        [#{files_list_source}].each_with_index do |_f, _i|
          load _f
          Minitest::Runnable.runnables.each { |_klass| _rank[_klass] ||= _i }
        end
        require #{path.inspect}
        Mutineer::MinitestIntegration.keep_file_order(_rank)
      RUBY
    end

    # Installs the RSpec seed watcher. The subprocess must do this before it
    # loads `--require` files, so a `config.seed=` there is recorded (#282).
    #
    # @api private
    # @return [String] Ruby script text.
    def rspec_seed_install
      seed = File.expand_path("test_runners/rspec_seed.rb", __dir__)
      <<~RUBY.chomp
        require #{seed.inspect}
        Mutineer::TestRunners::RSpecSeed.install!
      RUBY
    end

    # Ruby source that keeps spec files in the order given, the same hook as
    # {TestRunners::RSpec.run}. The seed watcher is installed earlier, before
    # the preloads ({#rspec_seed_install}).
    #
    # @api private
    # @param spec_list_source [String] Ruby source for the spec path arguments.
    # @return [String] Ruby script text.
    def rspec_order_preamble(spec_list_source)
      runner = File.expand_path("test_runners/rspec.rb", __dir__)
      <<~RUBY.chomp
        require #{runner.inspect}
        Mutineer::TestRunners::RSpec.keep_file_order([#{spec_list_source}])
      RUBY
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

    # Records every source line with a non-zero execution count as covered by
    # this test file. The counts are lines that ran after the sources loaded.
    # Coverage.result keys are absolute; relativize and drop any path outside
    # the project (stdlib/gem files).
    def record(coverage, test_path)
      rel_test = relativize(test_path)
      each_covered_key(coverage) { |key| add_covering_test(key, rel_test) }
    end

    # Adds `rel_test` to the map entry for `key`, in `@test_paths` order.
    # A partial recapture appends a test that a full capture would have
    # recorded earlier. Sorting by the run's test order keeps the two maps
    # equal (#421). A full capture appends in order, so it takes the fast
    # path: sorting on every append made capture quadratic in the test count.
    #
    # @api private
    # @param key [String] a "file:line" map key.
    # @param rel_test [String] project-relative test path.
    # @return [void]
    def add_covering_test(key, rel_test)
      list = (@map[key] ||= [])
      last = list.last
      if last.nil? || test_index(last) < test_index(rel_test)
        list << rel_test
      else
        list << rel_test unless list.include?(rel_test)
        list.sort_by! { |test| test_index(test) }
      end
    end

    # Position of `rel` in `@test_paths`. A path outside the run sorts last.
    #
    # @api private
    # @param rel [String] project-relative test path.
    # @return [Integer]
    def test_index(rel)
      @test_index ||= @test_paths.each_with_index.to_h { |path, index| [relativize(path), index] }
      @test_index.fetch(rel, @test_index.length)
    end

    # Line counts for the map, with `def` lines of methods the test called
    # filled in. A fork capture already did that and sends plain arrays.
    #
    # @api private
    # @param coverage [Hash] counts per absolute file.
    # @return [Hash] the same files, values reduced to line-count arrays.
    def map_coverage(coverage)
      coverage.to_h do |file, data|
        lines = if data.is_a?(Hash) && (data.key?(:methods) || data.key?("methods"))
                  lines_with_called_defs(data)
                else
                  data
                end
        [file, lines]
      end
    end

    # Credits `test_path` with source lines that ran only while the sources
    # loaded, when this test is one that should keep them (#426).
    #
    # Standalone capture preloads every source in every test's process, so
    # those lines would otherwise put every `--test` file on the map and a
    # cache hit would check them all. The lines stay in {#load_lines} either
    # way. They stay on the map for a paired test in this run: under
    # `--strategy reload` that test can kill a mutant on the line by checking
    # a value the load built (#348, `Catalog.price`). When the run has no
    # paired test, every test keeps the lines, so that kill is not dropped.
    # A line the test also ran after load is already on the map.
    #
    # @api private
    # @param load_coverage [Hash, nil] the load snapshot from the child.
    # @param test_coverage [Hash] the post-load coverage from the child.
    # @param test_path [String] test file path.
    # @return [void]
    def record_paired_load_lines(load_coverage, test_coverage, test_path)
      return unless load_coverage.is_a?(Hash)

      rel_test = relativize(test_path)
      post = line_counts_by_rel(map_coverage(test_coverage))
      @source_rels ||= @source_paths.to_set { |path| relativize(absolute(path)) }
      load_coverage.each do |abs_file, data|
        rel = relativize(abs_file)
        next unless @source_rels.include?(rel)
        next unless credit_load_only_line?(rel, rel_test)

        counts = data.is_a?(Hash) ? data["lines"] : data
        next unless counts.is_a?(Array)

        post_counts = post[rel]
        counts.each_with_index do |count, idx|
          next unless count&.positive?
          next if post_counts&.[](idx)&.positive?

          add_covering_test("#{rel}:#{idx + 1}", rel_test)
        end
      end
    end

    # Line-count arrays from a coverage hash, keyed by project-relative path.
    #
    # @api private
    # @param coverage [Hash] counts per absolute file.
    # @return [Hash{String => Array}]
    def line_counts_by_rel(coverage)
      coverage.each_with_object({}) do |(abs_file, data), out|
        counts = data.is_a?(Hash) ? (data["lines"] || data[:lines]) : data
        next unless counts.is_a?(Array)

        out[relativize(abs_file)] = counts
      end
    end

    # Whether `rel_test` keeps lines of `rel_source` that ran only at load.
    # A paired test in the run does. When none of the run's tests pair with
    # the source, every test does.
    #
    # @api private
    # @param rel_source [String] project-relative source path.
    # @param rel_test [String] project-relative test path.
    # @return [Boolean]
    def credit_load_only_line?(rel_source, rel_test)
      paired = paired_tests_in_run(rel_source)
      paired.empty? || paired.include?(rel_test)
    end

    # Conventional tests for `rel_source` that this run actually captures.
    #
    # @api private
    # @param rel_source [String] project-relative source path.
    # @return [Array<String>] project-relative test paths.
    def paired_tests_in_run(rel_source)
      @paired_in_run ||= {}
      @paired_in_run[rel_source] ||= begin
        run = @test_paths.to_set { |path| relativize(path) }
        Pairing.infer_tests(rel_source, project_root: @project_root, prefer: @framework || "minitest")
               .select { |path| run.include?(path) }
      end
    end

    # True when a standalone cache was built with the #426 load-line rule
    # and the same paired tests would keep load-only lines now. Boot and
    # daemon maps never credited those lines to tests.
    #
    # @api private
    # @param cached [Hash] parsed coverage.json.
    # @return [Boolean]
    def standalone_load_lines_current?(cached)
      return true if @boot_path

      cached[NARROW_LOAD_LINES] == true && load_line_pairs_match?(cached)
    end

    # The tests in this run that {#credit_load_only_line?} treats as paired,
    # per source. An empty list means every test keeps the load-only lines.
    #
    # @api private
    # @return [Hash{String => Array<String>}] project-relative source to sorted test paths.
    def load_line_pairs
      @source_paths.filter_map do |source|
        rel = relativize(absolute(source))
        next if rel.start_with?("/")

        [rel, paired_tests_in_run(rel).sort]
      end.to_h
    end

    # True when `cached` recorded the same {#load_line_pairs} this run has now.
    # A missing key is a map saved before the pairing decision was stored.
    #
    # @api private
    # @param cached [Hash] parsed coverage.json.
    # @return [Boolean]
    def load_line_pairs_match?(cached)
      saved = cached[LOAD_LINE_PAIRS]
      return false unless saved.is_a?(Hash)

      current = load_line_pairs
      return false unless saved.keys.sort == current.keys.sort

      current.all? { |rel, tests| Array(saved[rel]).sort == tests }
    end

    # Adds the configured source lines that ran at load to {#load_lines}, and
    # the methods called at load to {#load_methods}. Lines of other files
    # (tests, helpers, gems) are dropped.
    #
    # @api private
    # @param coverage [Hash, nil] counts per absolute file, as {#record} reads
    #   them; a Hash entry can also hold "methods", as {#load_entry} builds it.
    # @return [void]
    def record_load(coverage)
      lines, methods = load_sets_from(coverage)
      return if lines.nil?

      @load_lines.merge(lines)
      @load_methods.merge(methods)
      return unless @collect_load

      @seen_load_lines = lines
      @seen_load_methods = methods
    end

    # Line and method keys that ran at load in `coverage`, limited to this
    # run's sources. `[nil, nil]` when `coverage` is not a snapshot.
    #
    # @api private
    # @param coverage [Hash, nil] counts per absolute file, as {#record_load} reads them.
    # @return [Array(Set, Set), Array(nil, nil)]
    def load_sets_from(coverage)
      return [nil, nil] unless coverage.is_a?(Hash)

      lines = Set.new
      methods = Set.new
      ours = coverage.select { |abs_file, _| source_rels.include?(relativize(abs_file)) }
      each_covered_key(ours) { |key| lines << key }
      ours.each do |abs_file, data|
        next unless data.is_a?(Hash) && data["methods"].is_a?(Array)

        data["methods"].each { |line, column| methods << "#{relativize(abs_file)}:#{line}:#{column}" }
      end
      [lines, methods]
    end

    # One file's line counts, with the `def` line of each method the test
    # called counted too (#209). A forked capture does not see the `def` lines
    # run, since the boot defined the methods before the test. Standalone
    # capture clears the load snapshot before the test, so it does not either.
    # Ruby counts no line when an endless method runs, so without this its
    # mutants would be `no_coverage` even when a test calls it. A line where
    # more than one method starts is not counted: the map keys tests by line,
    # so the test would also be credited with the methods it did not call.
    #
    # @api private
    # @param data [Hash] `Coverage` result for one file, with `:lines` and
    #   `:methods`, or the JSON shape from {#test_coverage_assignment}
    #   (`"lines"` and `"methods"` as `[line, column, count]` rows).
    # @return [Array, nil] line counts.
    def lines_with_called_defs(data)
      lines = data[:lines] || data["lines"]
      methods = data[:methods] || data["methods"]
      return lines unless lines && methods

      lines = lines.dup
      entries = method_call_entries(methods)
      starts = entries.map(&:first).tally
      entries.each do |line, count|
        lines[line - 1] = [lines[line - 1].to_i, count].max if count.positive? && starts[line] == 1
      end
      lines
    end

    # Start line and call count for each method in a Coverage method table.
    # A Hash is the live Coverage result. An Array is the JSON shape
    # `[line, column, count]` from {#test_coverage_assignment}.
    #
    # @api private
    # @param methods [Hash, Array] method counts.
    # @return [Array<Array(Integer, Integer)>] `[start_line, count]` pairs.
    def method_call_entries(methods)
      if methods.is_a?(Hash)
        methods.map { |key, count| [key[2], count.to_i] }
      else
        Array(methods).filter_map do |row|
          next unless row.is_a?(Array) && row.size >= 3 && row[0].is_a?(Integer) && row[2].is_a?(Numeric)

          [row[0], row[2].to_i]
        end
      end
    end

    # One file's load-time coverage in the shape {#record_load} reads: the line
    # counts, and the `[line, column]` of each method called at least once.
    # {#load_coverage_expression} builds the same shape in a capture child.
    #
    # @api private
    # @param lines [Array, nil] line counts.
    # @param methods [Hash, nil] `Coverage` method counts, keyed by
    #   `[owner, name, start_line, start_column, end_line, end_column]`.
    # @return [Hash{String => Array}]
    def load_entry(lines, methods)
      { "lines" => lines, "methods" => (methods || {}).filter_map { |key, count| key[2, 2] if count.positive? } }
    end

    # Ruby source of the capture child's load-time coverage: `Coverage.peek_result`
    # for the configured sources only, matched by real path (a Coverage key is
    # the path as required), so the payload does not carry every loaded gem.
    # Each entry has the shape {#load_entry} builds.
    #
    # @api private
    # @return [String] expression to embed in a capture subprocess script.
    def load_coverage_expression
      "Coverage.peek_result.filter_map { |f, v| key = Mutineer::FsPath.read((File.realpath(f) rescue f)); " \
        "[key, { \"lines\" => v[:lines], \"methods\" => v[:methods].filter_map { |k, n| k[2, 2] if n.positive? } }] " \
        "if #{abs_source_paths.map { |path| FsPath.read(path) }.inspect}.include?(key) }.to_h"
    end

    # Ruby that drops the line and method counts recorded while the sources
    # loaded, and leaves Coverage running for the test (#426). The same call
    # the fork capture uses before a test. The load snapshot in `_load` is
    # already a copy, so this does not erase {#load_lines}.
    #
    # @api private
    # @return [String] one statement for a capture subprocess script.
    def discard_load_counts_expression
      "Coverage.result(clear: true, stop: false)"
    end

    # Ruby that stores the test's post-load coverage in `_coverage`.
    # Each file keeps its line counts and every method as
    # `[start_line, start_column, count]`, so {#lines_with_called_defs} can
    # credit a `def` line the test called. A line that ran only while the
    # sources loaded is absent, because {#discard_load_counts_expression} ran
    # first. Coverage keys are US-ASCII with invalid bytes under LC_ALL=C,
    # so each key is read back with {FsPath.read} (#346).
    #
    # @api private
    # @return [String] statements for a capture subprocess script.
    def test_coverage_assignment
      <<~RUBY.chomp
        _raw = Coverage.result
        _coverage = _raw.to_h do |_f, _v|
          next [Mutineer::FsPath.read(_f), _v] unless _v.is_a?(Hash)

          [Mutineer::FsPath.read(_f),
           { "lines" => _v[:lines], "methods" => (_v[:methods] || {}).map { |_k, _n| [_k[2], _k[3], _n] } }]
        end
      RUBY
    end

    # Yields a "file:line" key for every project line with a non-zero count.
    #
    # @api private
    # @param coverage [Hash] counts per absolute file: an Array, or a Hash with "lines".
    # @yieldparam key [String] the "file:line" key.
    # @return [void]
    def each_covered_key(coverage)
      coverage.each do |abs_file, data|
        rel = relativize(abs_file)
        next if rel.start_with?("/") # outside project_root: not our source

        counts = data.is_a?(Hash) ? data["lines"] : data
        next unless counts.is_a?(Array) # a Coverage mode without line counts

        counts.each_with_index { |count, idx| yield "#{rel}:#{idx + 1}" if count&.positive? }
      end
    end

    # Ruby source of the child-side `$LOADED_FEATURES` filter (project `.rb` files).
    #
    # @api private
    # @return [String] expression to embed in a capture subprocess script.
    def loaded_files_expression
      root = FsPath.read(project_root_real)
      prefix = root.b
      prefix += "/".b unless prefix.end_with?("/".b)
      # Byte prefix: a UTF-8 root and a binary loaded path must not raise.
      # A raise here used to be rescued into an empty list, and an empty
      # dependency hash then matched a stale cache (#346).
      "begin; _root = #{prefix.inspect}; $LOADED_FEATURES.filter_map { |f| next unless f.b.end_with?(\".rb\".b); abs = (File.realpath(f) rescue next); Mutineer::FsPath.read(abs) if Mutineer::FsPath.bytes_start_with?(abs, _root) }; rescue StandardError; []; end"
    end

    # Canonical project root for loaded-feature matching (`/var` vs `/private/var`).
    #
    # @api private
    # @return [String] realpath of the project root when it exists.
    def project_root_real = ProjectPath.root_real(@project_root)

    # Project-local `.rb` files loaded in this process at capture time.
    #
    # @api private
    # @return [Array<String>] absolute realpaths.
    def capture_loaded_files
      root = FsPath.read(project_root_real)
      prefix = root.b
      prefix += "/".b unless prefix.end_with?("/".b)
      $LOADED_FEATURES.filter_map do |f|
        next unless f.b.end_with?(".rb".b)

        abs = File.realpath(f)
        FsPath.read(abs) if FsPath.bytes_start_with?(abs, prefix)
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
      root = FsPath.read(project_root_real)
      prefix = root.b
      prefix += "/".b unless prefix.end_with?("/".b)
      return unless FsPath.bytes_start_with?(abs, prefix)

      FsPath.bytes_delete_prefix(abs, prefix)
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
    # @param except [Array<String>] project-relative paths whose fingerprint
    #   may differ. A method-body edit of a run source is checked by the
    #   skeleton instead (#421). Any other loaded file still has to match.
    # @return [Boolean]
    def dependencies_match?(cached, except: [])
      deps = cached["dependencies"]
      return false unless deps.is_a?(Hash)

      skip = except.to_set
      deps.all? do |rel, fingerprint|
        next true if skip.include?(rel)

        abs = absolute(rel)
        File.file?(abs) && file_fingerprint(abs) == fingerprint
      end
    end

    # True when `cached` is a complete map for this exact run: same digest,
    # same loaded files, and the keys a later partial recapture needs.
    #
    # @api private
    # @param cached [Hash, nil] parsed coverage.json.
    # @return [Boolean]
    def cache_hit?(cached)
      cached && cached["digest"] == @digest && dependencies_match?(cached) &&
        cached.key?("load_methods") && cached.key?("timings") &&
        parallel_workers_match?(cached) && standalone_load_lines_current?(cached) &&
        partial_cache?(cached)
    end

    # True when `cached` has the keys {PARTIAL_CACHE_KEYS} names.
    #
    # @api private
    # @param cached [Hash] parsed coverage.json.
    # @return [Boolean]
    def partial_cache?(cached)
      PARTIAL_CACHE_KEYS.all? { |key| cached.key?(key) }
    end

    # Copies a saved map into this object. Boot mode keeps the load lines it
    # just read from the live boot.
    #
    # @api private
    # @param cached [Hash] parsed coverage.json.
    # @return [void]
    def apply_cache(cached)
      @map = cached["map"] || {}
      @timings = cached["timings"] || {}
      unless @boot_path
        @load_lines = Set.new(cached["load_lines"])
        @load_methods = Set.new(cached["load_methods"])
      end
      @failed_test_files = Array(cached["failed_test_files"])
      @failed_clean_tests = []
      @failed_clean_details = {}
      @clean_timeouts = {}
      @loaded_dependencies = cached["dependencies"] || {}
    end

    # How to recapture part of `cached`, or nil when the run must capture
    # every test. Nil covers a class-body edit, a moved line, a load-time
    # method whose body changed, a loaded file outside the run's sources, a
    # run input, and a change to which tests pair with a source (#421).
    #
    # @api private
    # @param cached [Hash, nil] parsed coverage.json.
    # @return [Hash, nil] `"removed"`, `"recapture"`, and `"changed_sources"`.
    def partial_plan(cached)
      return nil unless cached.is_a?(Hash) && partial_cache?(cached)
      return nil unless cached.key?("load_methods") && cached.key?("timings")
      return nil unless parallel_workers_match?(cached) && standalone_load_lines_current?(cached)
      return nil unless cached["run_inputs"] == run_inputs_digest
      return nil unless dependencies_match?(cached, except: source_rels.to_a)

      tests = cached["tests"]
      sources = cached["sources"]
      skeletons = cached["skeletons"]
      return nil unless tests.is_a?(Hash) && sources.is_a?(Hash) && skeletons.is_a?(Hash)

      current_tests = test_fingerprints
      current_sources = source_fingerprints
      current_skeletons = source_skeletons
      return nil unless current_sources.keys.sort == sources.keys.sort

      changed_sources = []
      current_sources.each do |rel, fingerprint|
        next if sources[rel] == fingerprint

        skeleton = current_skeletons[rel]
        return nil if skeleton.nil? || skeletons[rel] != skeleton

        changed_sources << rel
      end
      return nil unless load_method_bodies_unchanged?(cached, changed_sources)
      return nil if @boot_path && load_record_changed?(cached, changed_sources)

      old_rels = tests.keys
      new_rels = current_tests.keys
      return nil if pairing_sets_changed?(old_rels, new_rels)

      removed = old_rels - new_rels
      added = new_rels - old_rels
      edited = (new_rels & old_rels).select { |rel| tests[rel] != current_tests[rel] }
      failed = Array(cached["failed_test_files"]) & new_rels
      touching = tests_in_source_entries(cached["map"], changed_sources) & new_rels
      recapture = (added + edited + failed + touching).uniq
      # Keeping nothing is a full capture. It rebuilds load lines in one pass.
      return nil if removed.empty? && recapture.size == new_rels.size

      { "removed" => removed, "recapture" => recapture, "changed_sources" => changed_sources }
    end

    # Rebuilds the tests in `plan` and keeps the rest. Returns false when the
    # recaptured load snapshot disagrees with the cache: the caller then
    # captures every test. A kept test is not credited with another source's
    # load-only lines, because those entries are left as the full capture
    # stored them and {#record_paired_load_lines} does not add them back.
    #
    # @api private
    # @param plan [Hash] the plan from {#partial_plan}.
    # @param cached [Hash] parsed coverage.json.
    # @param after_fork [Proc, nil] boot-mode fork hook.
    # @return [Boolean] true when the partial map was saved.
    def apply_partial(plan, cached, after_fork)
      apply_cache(cached)
      removed = plan["removed"]
      recapture = plan["recapture"]
      (removed + recapture).each { |rel| drop_test(rel) }
      @failed_test_files -= (removed + recapture)
      @collect_load = true
      @seen_load_lines = nil
      @seen_load_methods = nil
      @test_paths.each do |path|
        capture_one(path, after_fork) if recapture.include?(relativize(path))
      end
      @collect_load = false
      return false if !@boot_path && recapture.any? && partial_load_diverged?(cached)

      refresh_dependency_fingerprints(plan["changed_sources"] + recapture)
      # A removed test keeps its fingerprint: a kept test may still load
      # that file, and the map does not record which test loaded what.
      sort_map_entries
      @phase_a_ran = true if recapture.any?
      warn_recaptured(recapture.size, @test_paths.size)
      checked = clean_check_test_paths
      verify_cached_clean(after_fork: after_fork,
                          test_paths: checked.reject { |test| recapture.include?(relativize(test)) })
      verify_combined_clean(after_fork: after_fork)
      warn_unchecked("coverage cache", checked.size)
      save
      true
    end

    # Removes `rel` from every map entry and forgets its timing.
    #
    # @api private
    # @param rel [String] project-relative test path.
    # @return [void]
    def drop_test(rel)
      @map.each_value { |tests| tests.delete(rel) if tests.is_a?(Array) }
      @map.delete_if { |_key, tests| !tests.is_a?(Array) || tests.empty? }
      @timings.delete(rel)
    end

    # Puts every map entry in `@test_paths` order, which is the order a full
    # capture records tests.
    #
    # @api private
    # @return [void]
    def sort_map_entries
      @map.each_value { |tests| tests.sort_by! { |test| test_index(test) } if tests.is_a?(Array) }
    end

    # True when this boot's load lines or load methods for `changed_sources`
    # differ from the cache. The method body then changed what ran at boot,
    # so a kept test's coverage is not trusted.
    #
    # @api private
    # @param cached [Hash] parsed coverage.json.
    # @param changed_sources [Array<String>] project-relative source paths.
    # @return [Boolean]
    def load_record_changed?(cached, changed_sources)
      wanted = changed_sources.to_set
      pick = lambda do |keys|
        Array(keys).select { |key| wanted.include?(key_source(key)) }.to_set
      end
      pick.call(@load_lines) != pick.call(cached["load_lines"]) ||
        pick.call(@load_methods) != pick.call(cached["load_methods"])
    end

    # True when a recaptured standalone test saw different load lines than
    # the cache recorded. The body change reached load time.
    #
    # @api private
    # @param cached [Hash] parsed coverage.json.
    # @return [Boolean]
    def partial_load_diverged?(cached)
      return false unless @seen_load_lines

      @seen_load_lines != Set.new(Array(cached["load_lines"])) ||
        @seen_load_methods != Set.new(Array(cached["load_methods"]))
    end

    # Writes the current fingerprint of each `rels` entry over the cached one.
    # Only a path the cache already lists is refreshed: a test file that no
    # test loads is tracked by the "tests" fingerprints, as on a full capture.
    #
    # @api private
    # @param rels [Array<String>] project-relative paths.
    # @return [void]
    def refresh_dependency_fingerprints(rels)
      rels.each do |rel|
        next unless @loaded_dependencies.key?(rel)

        abs = absolute(rel)
        next unless File.file?(abs)

        @loaded_dependencies[rel] = file_fingerprint(abs)
      end
    end

    # Tests in `map` entries whose source is one of `source_rels`.
    #
    # @api private
    # @param map [Hash, nil] a "file:line" => [test files] map.
    # @param source_rels [Array<String>] project-relative source paths.
    # @return [Array<String>] project-relative test paths.
    def tests_in_source_entries(map, source_rels)
      return [] unless map.is_a?(Hash)

      wanted = source_rels.to_set
      map.each_with_object([]) do |(key, tests), list|
        next unless wanted.include?(key_source(key))

        Array(tests).each { |test| list << test if test.is_a?(String) && !list.include?(test) }
      end
    end

    # True when the conventional pair for any run source is a different set
    # of tests than the cache was built with. Load-only lines would move.
    #
    # @api private
    # @param old_rels [Array<String>] project-relative tests in the cache.
    # @param new_rels [Array<String>] project-relative tests in this run.
    # @return [Boolean]
    def pairing_sets_changed?(old_rels, new_rels)
      old_set = old_rels.to_set
      new_set = new_rels.to_set
      source_rels.any? { |rel| paired_among(rel, old_set) != paired_among(rel, new_set) }
    end

    # Conventional tests for `source_rel` that are in `test_rels`.
    #
    # @api private
    # @param source_rel [String] project-relative source path.
    # @param test_rels [Set<String>] project-relative test paths.
    # @return [Array<String>]
    def paired_among(source_rel, test_rels)
      Pairing.infer_tests(source_rel, project_root: @project_root, prefer: @framework || "minitest")
             .select { |path| test_rels.include?(path) }
             .sort
    end

    # Project-relative paths of this run's sources.
    #
    # @api private
    # @return [Set<String>]
    def source_rels
      @source_rels ||= @source_paths.to_set { |path| relativize(absolute(path)) }
    end

    # Fingerprint of each test file, by project-relative path.
    #
    # @api private
    # @return [Hash{String => String}]
    def test_fingerprints
      @test_paths.to_h { |path| [relativize(absolute(path)), file_fingerprint(absolute(path))] }
    end

    # Digest of everything that forces a full capture except source and test
    # contents (#421). The source list is included, so adding a source still
    # captures every test: standalone capture loads every source.
    #
    # @api private
    # @return [String] hex digest.
    def run_inputs_digest
      digest = Digest::SHA256.new
      source_rels.to_a.sort.each do |rel|
        digest.update("source\0")
        digest.update(rel)
        digest.update("\0")
      end
      @require_paths.each { |path| digest_group(digest, "require", [digest_path(path)]) }
      digest_group(digest, "boot", [digest_path(@boot_path)]) if @boot_path
      ownership_paths.each do |rel|
        digest.update("owner\0")
        digest.update(rel)
        digest.update("\0")
      end
      @load_paths.sort.each { |load_path| digest.update("loadpath\0#{load_path}\0") }
      digest.update("framework\0#{@framework}\0")
      digest_test_seed(digest)
      digest.hexdigest
    end

    # Skeleton digest of each source, by project-relative path. Nil when the
    # file does not parse: a partial recapture then does not run.
    #
    # @api private
    # @return [Hash{String => String, nil}]
    def source_skeletons
      @source_paths.to_h { |path| [relativize(absolute(path)), source_skeleton_digest(absolute(path))] }
    end

    # Digest of `abs` with each method body blanked, plus the line of every
    # `def`. Two files match when the edit is inside method bodies and no
    # line moved. A comment outside a body, a class-body statement, and an
    # added or removed line do not match.
    #
    # @api private
    # @param abs [String] absolute source path.
    # @return [String, nil] hex digest, or nil when the file cannot be parsed.
    def source_skeleton_digest(abs)
      source = File.binread(abs)
      result = Prism.parse(source)
      return nil unless result.errors.empty?

      ranges = []
      tuples = []
      each_def(result.value) do |node|
        loc = node.body&.location
        range = body_byte_range(node)
        ranges << range if range
        tuples << [node.location.start_line, node.location.start_column, loc&.start_line, loc&.end_line]
      end
      digest = Digest::SHA256.new
      digest.update(blank_method_bodies(source, ranges))
      tuples.sort.each do |tuple|
        digest.update("\0")
        digest.update(tuple.map { |part| part.nil? ? "-" : part.to_s }.join(":"))
      end
      digest.hexdigest
    rescue SystemCallError
      nil
    end

    # Byte range of the body of `node`, after its name and parameters. Nil
    # when the body is empty. A `def` with `rescue` or `ensure` has a
    # BeginNode body that starts at the `def` keyword, so the range starts
    # where the signature ends: a same-line name or parameter edit is not a
    # body edit.
    #
    # @api private
    # @param node [Prism::DefNode] a method definition.
    # @return [Array(Integer, Integer), nil] half-open byte range.
    def body_byte_range(node)
      loc = node.body&.location
      return nil unless loc

      signature_end = [node.name_loc, node.parameters&.location, node.rparen_loc].compact.map(&:end_offset).max
      start = [loc.start_offset, signature_end].max
      start < loc.end_offset ? [start, loc.end_offset] : nil
    end

    # `source` with every method-body byte range replaced by one marker.
    # Nested bodies are one marker: the outer range already covers them.
    #
    # @api private
    # @param source [String] source bytes.
    # @param ranges [Array<Array(Integer, Integer)>] half-open byte ranges.
    # @return [String] binary skeleton text.
    def blank_method_bodies(source, ranges)
      return source if ranges.empty?

      skip = Array.new(source.bytesize, false)
      ranges.each do |start, finish|
        next if start.negative? || finish > source.bytesize

        (start...finish).each { |index| skip[index] = true }
      end
      out = +"".b
      source.each_byte.with_index do |byte, index|
        if skip[index]
          out << 0 unless index.positive? && skip[index - 1]
        else
          out << byte
        end
      end
      out
    end

    # Yields each `def` in `node`, including defs nested in another body.
    #
    # @api private
    # @param node [Prism::Node, nil] syntax node.
    # @yieldparam node [Prism::DefNode]
    # @return [void]
    def each_def(node, &block)
      return unless node.is_a?(Prism::Node)

      block.call(node) if node.is_a?(Prism::DefNode)
      node.child_nodes.each { |child| each_def(child, &block) }
    end

    # True when every load-time method of `changed_sources` still has the
    # body the cache recorded. A different body can change a value other
    # tests read without those tests appearing in this source's map.
    #
    # @api private
    # @param cached [Hash] parsed coverage.json.
    # @param changed_sources [Array<String>] project-relative source paths.
    # @return [Boolean]
    def load_method_bodies_unchanged?(cached, changed_sources)
      stored = cached["load_method_bodies"]
      return false unless stored.is_a?(Hash)

      wanted = changed_sources.to_set
      stored.all? do |key, digest|
        next true unless wanted.include?(key_source(key))
        next false unless digest.is_a?(String)

        body_digest_at(key) == digest
      end
    end

    # Body digest of each method in {#load_methods}, keyed the same way.
    # `"missing"` marks a `def` the file no longer has at that line.
    #
    # @api private
    # @return [Hash{String => String}]
    def current_load_method_bodies
      @load_methods.to_h { |key| [key, body_digest_at(key) || "missing"] }
    end

    # Digest of the method body at the `def` named by `key`, in the file as
    # it is now. Nil when that `def` is gone or the file does not parse.
    #
    # @api private
    # @param key [String] a "file:line:column" load-method key.
    # @return [String, nil] hex digest.
    def body_digest_at(key)
      rel, line, column = split_method_key(key)
      text = method_bodies(rel)&.[]([line, column])
      return nil if text.nil?

      Digest::SHA256.hexdigest(text)
    end

    # Method bodies in `rel`, keyed by the `def` line and column Coverage uses.
    # Nil when the file does not parse.
    #
    # @api private
    # @param rel [String] project-relative source path.
    # @return [Hash{Array(Integer, Integer) => String}, nil]
    def method_bodies(rel)
      @method_bodies ||= {}
      return @method_bodies[rel] if @method_bodies.key?(rel)

      abs = absolute(rel)
      return @method_bodies[rel] = nil unless File.file?(abs)

      source = File.binread(abs)
      result = Prism.parse(source)
      return @method_bodies[rel] = nil unless result.errors.empty?

      found = {}
      each_def(result.value) do |node|
        loc = node.body&.location
        text = if loc && loc.end_offset > loc.start_offset
                 source.byteslice(loc.start_offset, loc.end_offset - loc.start_offset)
               else
                 +""
               end
        found[[node.location.start_line, node.location.start_column]] = text
      end
      @method_bodies[rel] = found
    rescue SystemCallError
      @method_bodies[rel] = nil
    end

    # Source path, `def` line, and `def` column of a load-method key.
    #
    # @api private
    # @param key [String] a "file:line:column" key.
    # @return [Array(String, Integer, Integer)]
    def split_method_key(key)
      rel = key_source(key)
      line, column = key.delete_prefix("#{rel}:").split(":").map(&:to_i)
      [rel, line, column]
    end

    # Tells the user how many test files a partial recapture ran again.
    # Prints nothing when every file was recaptured or none was: the first
    # is a full capture, and the second kept the whole map.
    #
    # @api private
    # @param recaptured [Integer] test files captured again.
    # @param total [Integer] test files in the run.
    # @return [void]
    def warn_recaptured(recaptured, total)
      kept = total - recaptured
      return unless recaptured.positive? && kept.positive?

      warn "[mutineer] coverage cache: recaptured #{recaptured} of #{total} test files; kept #{kept}."
    end

    # True when `cached` records the same +PARALLEL_WORKERS+ value this process
    # has now. Rails reads that variable inside +parallelize+ and can run one
    # test file in several workers. A missing key is a map saved before this
    # value was stored. In-process runs and the daemon write this same file.
    #
    # @api private
    # @param cached [Hash] parsed coverage.json.
    # @return [Boolean]
    def parallel_workers_match?(cached)
      cached.key?("parallel_workers") && cached["parallel_workers"] == ENV.fetch("PARALLEL_WORKERS", nil)
    end

    # Digest each file's ROLE + relative path + content length + content, plus
    # the load_paths. Without role/path/length delimiters the digest collides
    # (("ab","c") == ("a","bc")) and is blind to source/test role swaps, silently
    # accepting a stale cached map.
    #
    # @param inputs_only [Boolean] leave out the sources and their owners.
    def compute_digest(inputs_only: false)
      d = Digest::SHA256.new
      digest_group(d, "source", @source_paths) unless inputs_only
      digest_group(d, "test", @test_paths)
      # One group per file: digest_group sorts, and the load order matters.
      @require_paths.each { |p| digest_group(d, "require", [digest_path(p)]) }
      digest_group(d, "boot", [digest_path(@boot_path)]) if @boot_path
      (inputs_only ? [] : ownership_paths).each do |rel|
        d.update("owner\0")
        d.update(rel)
        d.update("\0")
      end
      @load_paths.sort.each { |lp| d.update("loadpath\0#{lp}\0") }
      d.update("framework\0#{@framework}\0")
      digest_test_seed(d)
      d.hexdigest
    end

    # Adds the test seed inputs to `digest`. The seed sets the test order, and
    # the order can change which lines run (#282). Minitest: the configured
    # seed. A test helper that changes SEED is not digested, like any other
    # helper edit. RSpec: the pinned seed, SPEC_OPTS, and the project `.rspec`
    # files. `~/.rspec` and a `config.seed` in a spec helper are not digested;
    # a helper edit is seen when that file is part of the capture.
    # {#compute_digest} and {#run_inputs_digest} share this, so a seed change
    # never reaches a partial recapture (#421).
    #
    # @api private
    # @param digest [Digest::SHA256] the digest to update.
    # @return [void]
    def digest_test_seed(digest)
      if @framework == "rspec"
        digest.update("seed\0#{MinitestIntegration::PINNED_SEED}\0#{ENV['SPEC_OPTS']}\0")
        %w[.rspec .rspec-local].each do |name|
          path = File.join(@project_root, name)
          digest.update("rspec-opts\0#{name}\0")
          digest.update(File.file?(path) ? File.binread(path) : "")
          digest.update("\0")
        end
      else
        digest.update("seed\0#{MinitestIntegration.seed}\0")
      end
    end

    # Longer source files that can take a split test from a configured source.
    # Only their presence is digested. A content edit of a sibling does not
    # change pairing, and it does not rebuild coverage. Each directory is
    # listed once, even when many sources share it. A concern also digests
    # longer files in its namespace directory, because those files can own a
    # namespace split name (#408). A model does not digest a concern file:
    # the model keeps a split file it already pairs with.
    #
    # @return [Array<String>] project-relative paths, sorted.
    def ownership_paths
      root = File.expand_path(@project_root)
      listings = {}
      paths = @source_paths.flat_map do |source|
        rel = relativize(absolute(source))
        next [] if rel.start_with?("/")

        base, = Pairing.logical_path(rel)
        bases = [base]
        ns = Pairing.namespace_base(rel)
        bases << ns if ns
        bases.uniq.flat_map { |logical| owner_files(root, logical, listings) }
      end
      paths.uniq.sort
    end

    # Longer `.rb` files that can own a split name of `base`.
    #
    # @param root [String] expanded project root.
    # @param base [String] logical source path without extension.
    # @param listings [Hash{String => Array<String>}] directory children, filled once.
    # @return [Array<String>] project-relative paths.
    def owner_files(root, base, listings)
      name = File.basename(base)
      dir = File.dirname(base)
      folders = [dir == "." ? nil : dir]
      %w[app lib].each { |prefix| folders << (dir == "." ? prefix : File.join(prefix, dir)) }
      folders.uniq.flat_map do |folder|
        abs = folder ? File.join(root, folder) : root
        entries = listings.fetch(abs) do
          listings[abs] = File.directory?(abs) ? Dir.children(abs).map { |entry| FsPath.read(entry) } : []
        end
        entries.filter_map do |entry|
          next unless entry.end_with?(".rb")

          stem = entry.delete_suffix(".rb")
          next unless stem.start_with?("#{name}_") && stem.length > name.length

          folder ? File.join(folder, entry) : entry
        end
      end
    end

    # boot_path and require_paths are require-style paths (e.g. "config/environment",
    # no extension); resolve one to the file `require` loads: the path itself, then
    # ".rb", then a native extension. A folder of the same name (lib/my_gem/ next to
    # lib/my_gem.rb) is not the file.
    def digest_path(path)
      ["", ".rb", ".#{RbConfig::CONFIG['DLEXT']}"].map { |ext| "#{path}#{ext}" }
                                                .find { |p| File.file?(absolute(p)) } || "#{path}.rb"
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
        # Bytes, not a locale read: a magic-comment encoding such as EUC-JP
        # is not valid UTF-8, and the digest is of the file's bytes (#346).
        content = File.binread(absolute(p))
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

      JSON.parse(File.read(cache_path, encoding: "UTF-8"))
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
               "dependencies" => @loaded_dependencies, "map" => @map,
               "load_lines" => @load_lines.to_a.sort, "load_methods" => @load_methods.to_a.sort,
               "timings" => @timings, "parallel_workers" => ENV.fetch("PARALLEL_WORKERS", nil),
               NARROW_LOAD_LINES => true, "run_inputs" => run_inputs_digest,
               "sources" => source_fingerprints, "skeletons" => source_skeletons,
               "tests" => test_fingerprints, "load_method_bodies" => current_load_method_bodies }
      data[LOAD_LINE_PAIRS] = load_line_pairs unless @boot_path
      if @boot_path
        data.merge!("inputs" => compute_digest(inputs_only: true), "sources" => source_fingerprints,
                    "owners" => ownership_paths)
      end
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

    # The sources, then the `--require` files, in the order standalone
    # {Runner.execute} requires them before it forks the mutants (#217).
    #
    # @api private
    # @return [Array<String>] absolute paths.
    def abs_preload_paths = abs_source_paths + @require_paths.map { |p| absolute(p) }

    # Returns absolute load paths.
    #
    # @return [Array<String>] absolute load paths.
    def abs_load_paths   = @load_paths.map { |p| absolute(p) }

    # Relativizes a path against the project root (see {ProjectPath.relative}).
    #
    # @api private
    # @param path [String] path to relativize.
    # @return [String] relative path, or an absolute path when outside the root.
    def relativize(path) = ProjectPath.relative(path, @project_root)

    # Expands a path relative to the project root (see {ProjectPath.absolute}).
    #
    # @api private
    # @param path [String] path to expand.
    # @return [String] absolute path.
    def absolute(path) = ProjectPath.absolute(path, @project_root)
  end
end
