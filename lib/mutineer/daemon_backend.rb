# frozen_string_literal: true

require_relative "parser"
require_relative "result"
require_relative "coverage_map"
require_relative "daemon_client"
# No require_relative "runner" on purpose: runner.rb requires this file, and the
# reverse edge makes Ruby warn "circular require considered harmful" on every -w
# load. Runner is loaded first on every real path; requiring this file alone leaves
# it undefined. Rationale and the real fix: #75.

module Mutineer
  # Daemon execution backend. Boots the app ONCE in a persistent subprocess under
  # the app's own bundle and forks per mutant, so a Rails run pays the boot cost
  # once instead of per mutant. Tool-side this only discovers jobs and builds the
  # ready-to-`load` payload (Prism); the daemon needs no Prism/mutineer.
  #
  # When jobs > 1 each worker runs against its OWN database, which is what makes
  # `--jobs N` safe under Rails (#26): parallel verdicts are identical to serial.
  #
  # Job collection, `--since` filtering and coverage selection stay on {Runner} and
  # are called from here, so the daemon path can never drift from the in-process
  # path on which mutants run or which tests narrow a mutant (score parity).
  #
  # Unlike {ExternalBackend}, which is a leaf {Runner} calls into, this module owns
  # its orchestration and calls back for that shared vocabulary.
  module DaemonBackend
    # Default per-mutant timeout on the daemon path (seconds), overridden by
    # config.daemon_timeout. Coverage narrowing usually keeps each job short; this
    # still covers a slow suite or full-suite fallback when the map is unavailable.
    # Named like its in-process counterpart {Isolation::DEFAULT_TIMEOUT}, not like
    # {ExternalBackend::SMOKE_TIMEOUT}, which bounds a different thing.
    DEFAULT_TIMEOUT = 60

    # Full daemon run: collect jobs, build the coverage map once, then execute
    # serially or across N worker daemons. Fail-fast forces serial so the survivor
    # set matches jobs 1.
    #
    # @param config [Mutineer::Config] run configuration (daemon set).
    # @param operator_classes [Array<Class>] resolved operators.
    # @return [Array(Mutineer::AggregateResult, Hash<String,String>)] aggregate and source map.
    def self.execute(config, operator_classes)
      jobs, ignored_results, source_map = Runner.collect_jobs(config, operator_classes)
      jobs = Runner.filter_since(jobs, source_map, config) if config.since
      abs_tests = config.tests.map { |t| File.expand_path(t, config.project_root) }

      # Build the coverage map once (app-side). nil when the build fails: runners
      # fall back to the full --test set (and emit a stderr warning) rather than
      # mis-scoring everything as no_coverage.
      coverage_map = build_coverage_map(config, abs_tests)

      # Worker count = resolved --jobs, capped at the job count (no idle daemons).
      # >1 → N concurrent daemon handles, each on its OWN worker DB (N-handles, the
      # spike-proven shape). 1 → the serial single-daemon path. --fail-fast forces
      # serial: parallel's stop flag fires on the first survivor by WALL-CLOCK, not
      # input index, so the verdict set would diverge from serial (a different,
      # non-deterministic survivor set/score). The "identical to --jobs 1" guarantee
      # below only holds when fail-fast cannot race.
      worker_count = [config.jobs || 1, 1].max
      worker_count = 1 if config.fail_fast
      worker_count = [worker_count, jobs.size].min if jobs.size.positive?

      results =
        if worker_count > 1
          run_parallel(jobs, worker_count, config, abs_tests, coverage_map, source_map)
        else
          run_serial(jobs, config, abs_tests, coverage_map, source_map)
        end

      [AggregateResult.new(results + ignored_results), source_map]
    end

    # Build the coverage map via a short-lived daemon (boots the app once, captures
    # per-test coverage app-side, ships the map back). Returns a query-only
    # CoverageMap, or nil when the build fails / returns empty. Callers then run the
    # full --test set. Coverage-build IPC has no wall-clock (same limitation as
    # in-process build_via_fork). A normal nonempty map scores like in-process;
    # nil falls back to the full suite (more testing, not comparable).
    #
    # @param config [Mutineer::Config] the run config.
    # @param abs_tests [Array<String>] absolute --test paths.
    # @return [Mutineer::CoverageMap, nil]
    def self.build_coverage_map(config, abs_tests)
      client = DaemonClient.new(boot: boot_config(config, abs_tests, coverage: true),
                                app_root: config.project_root).start
      data = begin
        client.coverage
      ensure
        client.quit
      end
      unless data && !(data["map"] || {}).empty?
        reason = data.is_a?(Hash) && data["error"] ? data["error"] : "empty map"
        warn_coverage_fallback(reason)
        return nil
      end

      CoverageMap.from_data(map: data["map"], failed_test_files: data["failed_test_files"] || [],
                            project_root: config.project_root)
    rescue DaemonBootError => e
      warn_coverage_fallback("#{e.class}: #{e.message}")
      nil
    end

    # Stderr note when daemon coverage is unavailable (full --test set per mutant).
    #
    # @api private
    # @param reason [String] short cause (boot error message, empty map, …).
    # @return [void]
    def self.warn_coverage_fallback(reason = "unknown")
      warn "[mutineer] daemon coverage map unavailable (#{reason}); running every " \
           "mutant against the full --test set (score not comparable to an in-process run)."
    end
    private_class_method :warn_coverage_fallback

    # Serial path: one daemon (worker 0), one mutant at a time. Honors --fail-fast
    # (stop at the first survivor).
    #
    # @api private
    # @return [Array<Mutineer::Result>] results in input order.
    def self.run_serial(jobs, config, abs_tests, coverage_map, source_map)
      client = DaemonClient.new(boot: boot_config(config, abs_tests),
                                app_root: config.project_root).start
      results = []
      begin
        jobs.each_with_index do |job, i|
          r = job_result(job, i, client, 0, config, coverage_map, abs_tests, source_map)
          results << r
          break if config.fail_fast && r.survived?
        end
      ensure
        client.quit
      end
      results
    end

    # Parallel path: N daemon handles, each pinned to its own worker slot (own DB).
    # A shared queue of job indices feeds N tool-side threads; results are placed by
    # input index so the verdict set matches serial. Callers must not pass fail_fast
    # here ({execute} forces serial for fail-fast). Per-mutant crashes are classified
    # in {job_result}, shared with the serial path; a {DaemonBootError} ends the run
    # here rather than scoring the remainder against a daemon that has given up.
    #
    # @api private
    # @return [Array<Mutineer::Result>] one result per input job, in input order.
    def self.run_parallel(jobs, worker_count, config, abs_tests, coverage_map, source_map)
      results = Array.new(jobs.size)
      queue   = Queue.new
      jobs.each_index { |i| queue << i }

      clients = Array.new(worker_count) do
        DaemonClient.new(boot: boot_config(config, abs_tests),
                         app_root: config.project_root).start
      end

      clients.each_with_index.map do |client, worker|
        Thread.new do
          # The abort below is re-raised by join and reported once there; without
          # this Ruby also dumps the thread's backtrace, which the serial path never
          # does. Same fault, same output, whatever --jobs is set to.
          Thread.current.report_on_exception = false
          loop do
            i = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            results[i] = job_result(jobs[i], i, client, worker, config, coverage_map, abs_tests, source_map)
          end
        rescue DaemonBootError
          # The daemon gave up for good. Stop feeding the other workers rather
          # than letting them score the rest of the run against a dead client;
          # Thread#join re-raises this and ends the run.
          queue.clear
          raise
        ensure
          client.quit
        end
      end.each(&:join)

      # Every job was popped by some worker and every pop assigns, so no slot can
      # be nil here: an escaping exception aborts the run via join instead.
      results
    end

    # Build the payload for one job, run it on the given daemon/worker, and attach
    # the subject/mutation/id. Shared body of both daemon paths, so `--jobs 1` and
    # `--jobs N` classify an identical fault identically.
    #
    # Error model, in one place because both paths call this: a crash while running
    # ONE mutant is that mutant's `error` verdict and the run continues, matching
    # {WorkerPool} and the daemon's own in-band crash reply. {DaemonBootError} is
    # different — DaemonClient raises it when the daemon is gone for good (a failed
    # boot handshake, a spawn the OS refused, or MAX_RESTARTS crashes) — so it
    # propagates and ends the run. Scoring the remaining mutants against a dead
    # daemon would print a score built on a fraction of the work. Anyone adding a
    # second fatal error class must re-raise it alongside {DaemonBootError} below.
    #
    # @param job [Array(Mutineer::Subject, Mutineer::Mutation, String)] the work item.
    # @param req_id [Integer] request id (echoed back for IPC ordering safety).
    # @param client [Mutineer::DaemonClient] the daemon handle to run on.
    # @param worker [Integer] the worker slot (→ worker DB) this daemon routes to.
    # @api private
    # @raise [Mutineer::DaemonBootError] when the daemon has given up; ends the run.
    # @return [Mutineer::Result] the decorated result.
    def self.job_result(job, req_id, client, worker, config, coverage_map, abs_tests, source_map)
      subject, mutation, id = job
      source  = source_map[subject.file]
      mutated = mutation.apply(source)
      # Skip an invalid mutant tool-side: never ship a payload that would fail to
      # load and read as a false `killed`.
      # Narrow to covering tests (shared with the in-process path via
      # Runner.coverage_selection, so scores match). :verdict = no_coverage/uncapturable,
      # no fork. No map (build failed) → run the full --test set (fallback, not
      # narrowed).
      sel = coverage_map && Runner.coverage_selection(subject.file, mutation, subject, source, coverage_map)
      r =
        if Parser.parse_string(mutated).errors.any?
          Result.skipped
        elsif sel && sel[0] == :verdict
          sel[1]
        else
          # Only the daemon call is guarded. A fault in the tool-side work above
          # (apply, the Prism parse, coverage selection) is deterministic — it would
          # hit every mutant — so it must stay fatal instead of becoming N error
          # verdicts and an empty denominator.
          begin
            verdict = client.request(
              id: req_id, worker: worker, timeout: config.daemon_timeout || DEFAULT_TIMEOUT,
              payload: { "code" => mutated, "source_file" => File.expand_path(subject.file, config.project_root) },
              tests: sel ? sel[1] : abs_tests
            )
            result_for(verdict)
          rescue DaemonBootError
            raise
          rescue StandardError => e
            Result.error("daemon worker crashed: #{e.class}: #{e.message}")
          end
        end
      r.with(subject: subject, mutation: mutation, id: id)
    end

    # The boot config the daemon needs to boot the app once: where to boot, the test
    # load roots (so `require "test_helper"` resolves in every fork), framework, and
    # whether this is Rails.
    #
    # @param config [Mutineer::Config] the run config.
    # @param abs_tests [Array<String>] absolute --test paths.
    # @param coverage [Boolean] whether this daemon builds the coverage map.
    # @return [Hash] the boot config shipped to the daemon.
    def self.boot_config(config, abs_tests, coverage: false)
      {
        project_root: config.project_root,
        boot: File.expand_path(config.boot || "config/environment", config.project_root),
        load_paths: Runner.test_load_roots(abs_tests),
        source_dirs: Runner.source_dirs(config), # so the daemon can sweep orphan mutant temps
        framework: config.framework,
        rails: config.rails,
        # Schema for per-worker DB isolation. Sent when present; the daemon
        # skips worker-DB schema loading if the path is absent (e.g. structure.sql apps).
        schema: schema_path(config),
        # Coverage narrowing. Only the short-lived map-building daemon starts
        # Coverage (before boot); worker daemons boot with it OFF (no wasted
        # instrumentation/memory across every mutant fork). `sources`/`tests` are the
        # map-build inputs.
        coverage: coverage,
        sources: config.sources.map { |s| File.expand_path(s, config.project_root) },
        tests: abs_tests
      }
    end

    # Absolute path to the app's `db/schema.rb` if it exists, else nil. Used by the
    # daemon to schema-load each fork's isolated worker database. Only `schema.rb`
    # is supported this pass; `structure.sql` apps get nil and fall back to
    # whatever the worker DB already holds.
    #
    # @param config [Mutineer::Config] the run config.
    # @api private
    # @return [String, nil] absolute schema path or nil.
    def self.schema_path(config)
      path = File.expand_path("db/schema.rb", config.project_root)
      File.exist?(path) ? path : nil
    end

    # Map a daemon verdict string to a Result. The daemon reports the four
    # run-time states it can decide; pre-fork states (skipped/no_coverage/…) are
    # resolved tool-side before a request is ever sent.
    #
    # @param verdict [String] the daemon's verdict word.
    # @api private
    # @return [Mutineer::Result] the matching result.
    def self.result_for(verdict)
      case verdict
      when "survived" then Result.survived
      when "killed"   then Result.killed
      when "timeout"  then Result.timeout
      else Result.error("daemon verdict: #{verdict}")
      end
    end

    # The module's contract is {execute} (the backend entry point) plus the two the
    # tests drive directly: {boot_config} from the zero-dep suite and
    # {build_coverage_map} from the daemon suite. Everything else is daemon-pipeline
    # internals with no caller outside this file.
    private_class_method :run_serial, :run_parallel, :job_result, :schema_path, :result_for
  end
end
