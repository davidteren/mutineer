# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "rbconfig"
require "coverage"
require "prism"
require "set"
require_relative "minitest_integration"
require_relative "minitest_failure_report"
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
require_relative "coverage_map/clean_check"
require_relative "coverage_map/child_scripts"

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
    include CleanCheck
    include ChildScripts

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

    # Seconds the separate clean checks ran tests ({#verify_cached_clean},
    # {#verify_combined_clean}), or nil when neither ran a test (#495). On a
    # cache miss each test also ran alone during capture; that time is in the
    # capture, not here.
    #
    # @return [Float, nil]
    attr_reader :clean_check_seconds

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
    # @param clean_check_seconds [Float, nil] seconds the clean checks ran ({#clean_check_seconds}).
    # @param fallback [Boolean] the daemon could not build a map ({#fallback?}).
    # @return [Mutineer::CoverageMap] a query-only map.
    def self.from_data(map:, failed_test_files:, project_root:, failed_clean_tests: [],
                       failed_clean_details: {}, load_lines: [],
                       load_methods: [], timings: {}, clean_timeouts: {}, clean_check_seconds: nil,
                       fallback: false)
      instance = allocate
      instance.instance_variable_set(:@fallback, fallback)
      instance.instance_variable_set(:@map, map || {})
      instance.instance_variable_set(:@timings, timings || {})
      instance.instance_variable_set(:@load_lines, Set.new(load_lines || []))
      instance.instance_variable_set(:@load_methods, Set.new(load_methods || []))
      instance.instance_variable_set(:@failed_test_files, failed_test_files || [])
      instance.instance_variable_set(:@failed_clean_tests, failed_clean_tests || [])
      instance.instance_variable_set(:@failed_clean_details, failed_clean_details || {})
      instance.instance_variable_set(:@clean_timeouts, clean_timeouts || {})
      instance.instance_variable_set(:@clean_check_seconds, clean_check_seconds)
      instance.instance_variable_set(:@project_root, FsPath.read(project_root))
      instance
    end

    def initialize(source_paths:, test_paths:, cache_dir: ".mutineer",
                   load_paths: ["lib"], project_root: Dir.pwd,
                   capture_timeout: DEFAULT_CAPTURE_TIMEOUT, boot_path: nil,
                   framework: "minitest", verbose: false, require_paths: [], coverage_from: nil,
                   extra_load_paths: [])
      @source_paths = Array(source_paths).map { |path| FsPath.read(path) }
      @require_paths = Array(require_paths).map { |path| FsPath.read(path) }
      @test_paths   = Array(test_paths).map { |path| FsPath.read(path) }
      @cache_dir    = FsPath.read(cache_dir)
      @coverage_from = coverage_from && FsPath.read(coverage_from)
      @load_paths   = Array(load_paths).map { |path| FsPath.read(path) }
      # The user's load_path directories (#491), in order; part of the cache key.
      @extra_load_paths = Array(extra_load_paths).map { |path| FsPath.read(path) }
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
      @clean_check_seconds = nil
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

    # True for the map the daemon returns when it could not build one: it
    # holds only boot lines, and every mutant runs every test the run kept
    # ({DaemonBackend.job_result}). Any other map, an empty one included,
    # selects tests by coverage (#496).
    #
    # @return [Boolean]
    def fallback? = @fallback == true

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
