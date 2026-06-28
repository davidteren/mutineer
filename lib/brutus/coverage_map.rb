# frozen_string_literal: true

require "open3"
require "json"
require "digest"
require "fileutils"
require "rbconfig"

module Brutus
  # Maps `(source_file, line) -> [test_files]` so each mutant runs only against
  # the tests that actually exercise its line. Built once (Phase A), then queried
  # per mutant (Phase B via #tests_for). Persisted to .brutus/coverage.json with
  # a content-based digest that rebuilds the map whenever any tracked file changes.
  #
  # Keys are "file:line" strings (relative to project_root) everywhere — in
  # memory and on disk — so load/save needs no key transformation (KTD4).
  class CoverageMap
    DEFAULT_CAPTURE_TIMEOUT = 120 # seconds, per coverage subprocess (R3)

    attr_reader :project_root, :failed_test_files, :phase_a_ran

    def initialize(source_paths:, test_paths:, cache_dir: ".brutus",
                   load_paths: ["lib"], project_root: Dir.pwd,
                   capture_timeout: DEFAULT_CAPTURE_TIMEOUT)
      @source_paths = Array(source_paths)
      @test_paths   = Array(test_paths)
      @cache_dir    = cache_dir
      @load_paths   = Array(load_paths)
      @project_root = project_root
      @capture_timeout = capture_timeout
      @map          = {}
      @failed_test_files = []
      @phase_a_ran  = false
    end

    # Phase A entry point: load the cached map when the content digest matches,
    # otherwise rebuild from subprocesses and overwrite the cache.
    def build_or_load
      warn_external_sources
      @digest = compute_digest

      cached = read_cache
      if cached && cached["digest"] == @digest
        @map = cached["map"] || {}
        @failed_test_files = cached["failed_test_files"] || []
        warn_incomplete unless @failed_test_files.empty?
        return self
      end

      run_phase_a
      save
      self
    end

    # Phase B lookup: the test files that cover `file:line`, or [] when none do.
    # ponytail: per-file granularity; upgrade to per-method when throughput
    # warrants (requires Minitest method isolation + finer Coverage tracking).
    def tests_for(file, line)
      @map["#{relativize(file)}:#{line}"] || []
    end

    private

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

    def fail_test(test_path, reason)
      rel = relativize(test_path)
      @failed_test_files << rel
      warn "[brutus] coverage skipped for #{rel}: #{reason}"
      nil
    end

    def subprocess_script(test_path)
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
      @load_paths.sort.each { |lp| d.update("loadpath\0#{lp}\0") }
      d.hexdigest
    end

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

        warn "[brutus] source #{p} is outside project root #{@project_root}; " \
             "its coverage will be ignored"
      end
    end

    def cache_path = File.join(@cache_dir, "coverage.json")

    def read_cache
      return nil unless File.exist?(cache_path)

      JSON.parse(File.read(cache_path))
    rescue JSON::ParserError
      nil # corrupt cache — rebuild from scratch
    end

    def save
      FileUtils.mkdir_p(@cache_dir)
      data = { "digest" => @digest, "failed_test_files" => @failed_test_files, "map" => @map }
      tmp = "#{cache_path}.tmp"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, cache_path) # atomic swap
    end

    def warn_incomplete
      warn "[brutus] cached coverage map may be incomplete; these test files " \
           "failed to contribute: #{@failed_test_files.join(', ')}"
    end

    def abs_source_paths = @source_paths.map { |p| absolute(p) }
    def abs_load_paths   = @load_paths.map { |p| absolute(p) }

    def relativize(path)
      return path unless path.start_with?("/")

      path.delete_prefix("#{@project_root}/")
    end

    def absolute(path)
      File.absolute_path?(path) ? path : File.expand_path(path, @project_root)
    end
  end
end
