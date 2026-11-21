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
require_relative "coverage_map/cache"
require_relative "coverage_map/skeleton_digest"
require_relative "coverage_map/recording"

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
    include Cache
    include SkeletonDigest
    include Recording

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
