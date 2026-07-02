# frozen_string_literal: true

require "open3"
require "json"
require "digest"
require "fileutils"
require "rbconfig"
require "coverage"
require "set"
require_relative "minitest_integration"
require_relative "test_runners"

module Mutineer
  # Maps `(source_file, line) -> [test_files]` so each mutant runs only against
  # the tests that actually exercise its line. Built once (Phase A), then queried
  # per mutant (Phase B via #tests_for). Persisted to .mutineer/coverage.json with
  # a content-based digest that rebuilds the map whenever any tracked file changes.
  #
  # Keys are "file:line" strings (relative to project_root) everywhere — in
  # memory and on disk — so load/save needs no key transformation (KTD4).
  class CoverageMap
    DEFAULT_CAPTURE_TIMEOUT = 120 # seconds, per coverage subprocess (R3)

    attr_reader :project_root, :failed_test_files, :phase_a_ran, :map

    # Build a QUERY-ONLY map from data captured elsewhere (the daemon builds the map
    # app-side and ships `map` + `failed_test_files` over IPC; the tool reconstructs it
    # here for per-mutant selection). Skips the capture machinery entirely — only the
    # three fields #tests_for / #method_uncapturable? read are set (U7).
    #
    # @param map [Hash] the "file:line" => [test_files] map.
    # @param failed_test_files [Array<String>] test files whose capture failed.
    # @param project_root [String] project root (for path relativization).
    # @return [Mutineer::CoverageMap] a query-only map.
    def self.from_data(map:, failed_test_files:, project_root:)
      instance = allocate
      instance.instance_variable_set(:@map, map || {})
      instance.instance_variable_set(:@failed_test_files, failed_test_files || [])
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
      @phase_a_ran  = false
    end

    # Phase A entry point (standalone): load the cached map when the content
    # digest matches, otherwise rebuild from subprocesses and overwrite the cache.
    def build_or_load
      warn_external_sources
      cached_or { run_phase_a }
    end

    # Boot-mode Phase A: Coverage is already running in the parent (started before
    # the app booted, so booted source lines are instrumented). A clean `ruby`
    # subprocess has no booted env, so per-test coverage is captured by FORKING
    # the booted parent instead. Inverts into the same map #tests_for reads, and
    # reuses the digest cache (the digest mixes in the boot file so a boot cache
    # never collides with a standalone one).
    def build_via_fork(after_fork: nil)
      warn_external_sources
      cached_or { run_phase_a_via_fork(after_fork: after_fork) }
    end

    # Phase B lookup: the test files that cover `file:line`, or [] when none do.
    # ponytail: per-file granularity; upgrade to per-method when throughput
    # warrants (requires Minitest method isolation + finer Coverage tracking).
    def tests_for(file, line)
      @map["#{relativize(file)}:#{line}"] || []
    end

    # #9: is this source file's empty coverage the result of an *errored* capture
    # rather than a genuine coverage gap? True iff (KTD-2) some capture failed this
    # run AND this file got zero coverage from any successful capture AND a failed
    # test file maps to it by the standard _test/_spec naming convention. Derived
    # purely from already-persisted state (@map keys + @failed_test_files); no rerun,
    # no new cached field, no digest change.
    #
    # ponytail: file-level, convention-based attribution. A line covered only by a
    # failed test in an otherwise-covered file stays no_coverage (condition 2), and
    # a source with no naming-convention test match is never tainted. Upgrade path:
    # persist per-file coverage per successful run and diff against the failed set,
    # or record test->source targets explicitly. Not needed for the #8/#9 cases.
    def uncapturable_source?(file)
      return false if @failed_test_files.empty?

      rel = relativize(absolute(file))
      return false if covered_source_files.include?(rel)

      failed_test_targets.include?(File.basename(rel, ".rb"))
    end

    # #25: per-METHOD taint. A mutant on a line whose enclosing method got zero
    # successful coverage, in a file a failed sibling test targets, is
    # :uncapturable (the capture that would have covered it errored) — NOT a
    # genuine gap. A method with any covered line means its uncovered lines are a
    # real :no_coverage. A failed capture emits no coverage, so per-line intent is
    # unknowable; method-range + successful coverage is the finest derivable signal.
    # Fully-failed files behave exactly as uncapturable_source? did (every method
    # range has zero coverage), so #8/#9/#19 behavior is unchanged.
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
    # yield to populate @map and persist it.
    def cached_or
      @digest = compute_digest
      cached = read_cache
      if cached && cached["digest"] == @digest
        @map = cached["map"] || {}
        @failed_test_files = cached["failed_test_files"] || []
        warn_incomplete unless @failed_test_files.empty?
        return self
      end

      yield
      save
      self
    end

    # Runs standalone Phase A coverage capture.
    #
    # @api private
    def run_phase_a
      @phase_a_ran = true
      @map = {}
      @failed_test_files = []

      @test_paths.each do |test_path|
        coverage = capture(test_path)
        next unless coverage

        record(coverage, test_path)
      end
    end

    # Boot-mode Phase A. For each test file, fork the booted parent; the child
    # resets its Coverage delta, runs that ONE test, and marshals back the raw
    # per-source coverage counts. record() inverts them exactly as the subprocess
    # path does. ponytail: serial fork (one test at a time) — boot apps fork
    # cheaply via COW and per-test isolation matters more than throughput here.
    def run_phase_a_via_fork(after_fork:)
      @phase_a_ran = true
      @map = {}
      @failed_test_files = []
      abs_sources = abs_source_paths

      @test_paths.each do |test_path|
        # Tri-state payload (KTD-1): Hash = coverage, String = error diagnostic
        # from the child, nil = pipe gone / empty.
        # ponytail/#9: this String diagnostic is what #9 turns into an :uncapturable status.
        case (coverage = fork_capture(absolute(test_path), abs_sources, after_fork))
        when Hash   then record(coverage, test_path)
        when String
          fail_test(test_path, @verbose ? "fork capture failed: #{coverage}" :
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
      # #19: Marshal output is binary — an un-binmoded pipe can raise
      # Encoding::UndefinedConversionError on write, which the child's rescue then
      # swallows, losing the real error and yielding a bare "no result".
      rd.binmode
      wr.binmode
      pid = fork do
        rd.close
        payload =
          begin
            # Fork-safety hook: the in-process path reconnects AR; the daemon routes
            # to its worker DB. Nil (non-Rails) = no-op. Injected so this file needs
            # neither Runner (Prism) nor Rails.
            after_fork&.call
            Coverage.result(clear: true, stop: false) # discard pre-test delta
            TestRunners.for(@framework).run([abs_test])
            # lines:true yields {file => {lines: [...]}}; reduce to the counts
            # array record() expects, keeping only our source files.
            Coverage.result(stop: false)
                    .select { |f, _| abs_sources.include?(f) }
                    .transform_values { |v| v.is_a?(Hash) ? v[:lines] : v }
          rescue Exception => e # rubocop:disable Lint/RescueException
            # KTD-1: stringify (an arbitrary Exception may not marshal); the parent
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
      # #19: an empty pipe means the child died before writing (e.g. a hard crash,
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
    # before any source is loaded (KTD1/KTD2). Returns the parsed Coverage.result
    # hash, or nil when the subprocess failed (logged + skipped per R6).
    def capture(test_path)
      out = +""
      status = nil
      Open3.popen2(RbConfig.ruby, "-") do |stdin, stdout, wait_thr|
        stdin.write(subprocess_script(test_path))
        stdin.close
        reader = Thread.new { out << stdout.read }
        # R3: bound the subprocess with a wall clock — a hanging test file must
        # not wedge the whole run before any per-mutant timeout.
        unless wait_thr.join(@capture_timeout)
          Process.kill(:KILL, wait_thr.pid) rescue nil # rubocop:disable Style/RescueModifier
          reader.kill
          return fail_test(test_path, "timed out after #{@capture_timeout}s")
        end
        reader.join
        status = wait_thr.value
      end
      return fail_test(test_path, "subprocess exited #{status.exitstatus}") unless status.success?

      JSON.parse(out)
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
        require "coverage"
        require "json"
        require "stringio"
        require "minitest"
        def Minitest.autorun; end
        Coverage.start(lines: true)
        $LOAD_PATH.unshift(*#{abs_load_paths.inspect})
        #{abs_source_paths.inspect}.each { |f| load f }
        load #{absolute(test_path).inspect}
        _orig = $stdout
        $stdout = StringIO.new
        Minitest.run([])
        $stdout = _orig
        puts Coverage.result.to_json
      RUBY
    end

    # Same coverage-JSON contract as the minitest path, but driven by RSpec:
    # require rspec/core lazily, load the sources under Coverage, then run the
    # one spec via RSpec::Core::Runner with output silenced so only the JSON
    # reaches stdout. A missing rspec makes `require` raise -> subprocess exits
    # non-zero -> capture() records a skipped (incomplete-map) test, with a hint.
    def rspec_subprocess_script(test_path)
      <<~RUBY
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
        _orig = $stdout
        _sink = StringIO.new
        $stdout = _sink
        RSpec::Core::Runner.run(["--no-color", #{absolute(test_path).inspect}], _sink, _sink)
        $stdout = _orig
        puts Coverage.result.to_json
      RUBY
    end

    # Records every source line with a non-zero execution count as covered by
    # this test file. Coverage.result keys are absolute; relativize and drop any
    # path outside the project (stdlib/gem files).
    def record(coverage, test_path)
      rel_test = relativize(test_path)
      coverage.each do |abs_file, data|
        rel = relativize(abs_file)
        next if rel.start_with?("/") # outside project_root — not our source

        counts = data.is_a?(Array) ? data : data["lines"]
        counts.each_with_index do |count, idx|
          next unless count&.positive?

          (@map["#{rel}:#{idx + 1}"] ||= []) << rel_test
        end
      end
    end

    # R4: digest each file's ROLE + relative path + content length + content, plus
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

    # R7: a configured source that resolves outside project_root would silently be
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
      nil # corrupt cache — rebuild from scratch
    end

    # Saves the coverage cache.
    #
    # @api private
    # @return [void]
    def save
      FileUtils.mkdir_p(@cache_dir)
      data = { "digest" => @digest, "failed_test_files" => @failed_test_files, "map" => @map }
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
      return path unless path.start_with?("/")

      path.delete_prefix("#{@project_root}/")
    end

    # Expands a path relative to the project root.
    #
    # @api private
    # @param path [String] path to expand.
    # @return [String] absolute path.
    def absolute(path)
      File.absolute_path?(path) ? path : File.expand_path(path, @project_root)
    end
  end
end
