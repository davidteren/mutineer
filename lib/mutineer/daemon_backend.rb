# frozen_string_literal: true

require_relative "parser"
require_relative "result"
require_relative "coverage_map"
require_relative "daemon_client"
require_relative "progress"
require_relative "job_plan"

module Mutineer
  # Daemon execution backend. Boots the app ONCE in a persistent subprocess under
  # the app's own bundle and forks per mutant, so a Rails run pays the boot cost
  # once instead of per mutant. Tool-side this only discovers jobs and builds the
  # ready-to-`load` payload (Prism); the daemon needs no Prism/mutineer.
  #
  # When jobs > 1 each worker runs against its OWN database, which is what makes
  # `--jobs N` safe under Rails (#26): parallel verdicts are identical to serial.
  #
  # Job collection, `--since` filtering and coverage selection live in {JobPlan},
  # which the in-process path calls too, so the daemon path can never drift from
  # it on which mutants run or which tests narrow a mutant (score parity).
  #
  # Unlike {ExternalBackend}, which is a leaf {Runner} calls into, this module owns
  # its orchestration and takes that shared vocabulary from {JobPlan}.
  module DaemonBackend
    # Default per-mutant timeout on the daemon path (seconds), overridden by
    # config.daemon_timeout. Coverage narrowing usually keeps each job short; this
    # still covers a slow suite or full-suite fallback when the map is unavailable.
    # Named like its in-process counterpart {Isolation::DEFAULT_TIMEOUT}, not like
    # {ExternalBackend::SMOKE_TIMEOUT}, which bounds a different thing.
    DEFAULT_TIMEOUT = 60

    # The daemon's per-mutant tempfile, written into the source dir so
    # require_relative resolves. Kept in step with DaemonServer#sweep_temps.
    DAEMON_TEMP_GLOB = "mutineer_daemon*.rb"

    # Full daemon run: collect jobs, build the coverage map once, then execute
    # serially or across N worker daemons. Fail-fast forces serial so the survivor
    # set matches jobs 1.
    #
    # @param config [Mutineer::Config] run configuration (daemon set).
    # @param operator_classes [Array<Class>] resolved operators.
    # @return [Array(Mutineer::AggregateResult, Hash<String,String>, Hash)] aggregate,
    #   source map, and the {JobPlan.collect_jobs} extras.
    def self.execute(config, operator_classes)
      jobs, ignored_results, source_map, extras = JobPlan.collect_jobs(config, operator_classes)
      jobs, ignored_results, extras[:unscoped_mutants] = JobPlan.scope_since(jobs, ignored_results, source_map, config)
      abs_tests = config.tests.map { |t| File.expand_path(t, config.project_root) }

      # Nothing to mutate (`--since` matched no changed line, or every mutant is
      # suppressed). Return before booting anything: the coverage daemon and the
      # worker daemons below each boot the whole app, and README documents
      # `--since origin/<base>` for PR CI, where a docs-only PR is routine.
      if jobs.empty?
        # The daemon sweeps orphaned temps at boot and nothing boots here, so sweep
        # tool-side. A file a hard-killed run left in app/models breaks the app's own
        # Zeitwerk boot, not just Mutineer's next run.
        JobPlan.sweep_orphans(JobPlan.source_dirs(config), DAEMON_TEMP_GLOB)
        return [AggregateResult.new(ignored_results), source_map, extras]
      end

      # Worker count = resolved --jobs, capped at the job count (no idle daemons).
      # >1 → N concurrent daemon handles, each on its OWN worker DB (N-handles, the
      # spike-proven shape). 1 → the serial single-daemon path. --fail-fast forces
      # serial: parallel's stop flag fires on the first survivor by WALL-CLOCK, not
      # input index, so the verdict set would diverge from serial (a different,
      # non-deterministic survivor set/score). The "identical to --jobs 1" guarantee
      # below only holds when fail-fast cannot race.
      # A second database config is only known after the app boots, so the first
      # daemon can still lower this count before any worker starts.
      worker_count = [config.jobs || 1, 1].max
      worker_count = 1 if config.fail_fast
      worker_count = [worker_count, jobs.size].min

      # One booted process copies Postgres worker databases, then builds the
      # coverage map. A cached map still provisions: the copy has to happen
      # while no worker is connected to the template database.
      coverage_map, worker_count = prepare_run(config, abs_tests, worker_count)

      results =
        if worker_count > 1
          run_parallel(jobs, worker_count, config, abs_tests, coverage_map, source_map)
        else
          run_serial(jobs, config, abs_tests, coverage_map, source_map)
        end

      [AggregateResult.new(results + ignored_results), source_map, extras]
    end

    # Build the coverage map via a short-lived daemon (boots the app once, captures
    # per-test coverage app-side, ships the map back). Returns a query-only
    # CoverageMap, or nil when the build fails / returns empty. Callers then run the
    # full --test set. An empty map that came with boot lines returns a map with
    # those lines only: it narrows nothing, but still classifies `ran_at_load`.
    # Each capture is bounded by capture_timeout (#101); the client's wait for
    # the whole map is not, because its length grows with the number of test
    # files. A normal nonempty map scores like in-process;
    # nil falls back to the full suite (more testing, not comparable).
    #
    # @param config [Mutineer::Config] the run config.
    # @param abs_tests [Array<String>] absolute --test paths.
    # @return [Mutineer::CoverageMap, nil]
    def self.build_coverage_map(config, abs_tests)
      client = DaemonClient.new(boot: boot_config(config, abs_tests, coverage: true),
                                app_root: config.project_root).start
      begin
        coverage_map_from_client(client, config)
      ensure
        client.quit
      end
    rescue DaemonBootTimeout
      raise
    rescue DaemonBootError => e
      warn_coverage_fallback("#{e.class}: #{e.message}")
      nil
    end

    # Boot the first daemon, copy worker databases, then read the coverage map
    # from that same process. A boot failure still falls back to the full test
    # set. A provisioning failure does not: it stops the run.
    #
    # @param config [Mutineer::Config]
    # @param abs_tests [Array<String>]
    # @param worker_count [Integer] slots requested before the database count is known.
    # @return [Array] the coverage map (or nil) and the worker count to start.
    def self.prepare_run(config, abs_tests, worker_count)
      client = nil
      begin
        client = DaemonClient.new(boot: boot_config(config, abs_tests, coverage: true),
                                  app_root: config.project_root).start
      rescue DaemonBootTimeout
        raise
      rescue DaemonBootError => e
        warn_coverage_fallback("#{e.class}: #{e.message}")
        return [nil, worker_count]
      end

      begin
        count = client.database_count.to_i
        if count > 1 && worker_count > 1
          warn "[mutineer] this app has #{count} databases; Mutineer runs one worker. " \
               "Parallel runs support one database."
          worker_count = 1
        end
        # Raises DaemonBootError. Callers must not score mutants after this.
        client.provision(worker_count)
        [coverage_map_from_client(client, config), worker_count]
      ensure
        client.quit
      end
    end

    # Turn one daemon's coverage reply into a map. Does not start or stop the daemon.
    #
    # @param client [Mutineer::DaemonClient]
    # @param config [Mutineer::Config]
    # @return [Mutineer::CoverageMap, nil]
    def self.coverage_map_from_client(client, config)
      data = client.coverage
      # A red unmutated suite must abort, even when the shipped map is empty.
      # Falling back to the full --test set would treat those failures as kills.
      if data.is_a?(Hash) && Array(data["failed_clean_tests"]).any?
        JobPlan.abort_if_unclean!(CoverageMap.from_data(
          map: data["map"] || {},
          failed_test_files: data["failed_test_files"] || [],
          project_root: config.project_root,
          failed_clean_tests: data["failed_clean_tests"]
        ))
      end

      unless data && !(data["map"] || {}).empty?
        reason = data.is_a?(Hash) && data["error"] ? data["error"] : "empty map"
        warn_coverage_fallback(reason)
        # No narrowing ({job_result} runs every test), but the lines and
        # methods that ran at boot still classify a survivor on one of them.
        load_lines = data.is_a?(Hash) ? Array(data["load_lines"]) : []
        load_methods = data.is_a?(Hash) ? Array(data["load_methods"]) : []
        return nil if load_lines.empty? && load_methods.empty?

        return CoverageMap.from_data(map: {}, failed_test_files: [], project_root: config.project_root,
                                     load_lines: load_lines, load_methods: load_methods)
      end

      CoverageMap.from_data(map: data["map"], failed_test_files: data["failed_test_files"] || [],
                            project_root: config.project_root, load_lines: data["load_lines"] || [],
                            load_methods: data["load_methods"] || [])
    rescue DaemonBootTimeout
      raise # a second daemon for the mutant runs would hang just as long
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
      progress = Progress.new(jobs.size)
      begin
        jobs.each_with_index do |job, i|
          r = job_result(job, i, client, 0, config, coverage_map, abs_tests, source_map)
          results << r
          progress.tick
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
      results  = Array.new(jobs.size)
      progress = Progress.new(jobs.size)
      queue    = Queue.new
      jobs.each_index { |i| queue << i }

      # Built one at a time so a refused spawn part-way (EMFILE under a high --jobs)
      # can still quit the daemons already up. Array.new would lose every reference.
      clients = []
      begin
        worker_count.times do
          clients << DaemonClient.new(boot: boot_config(config, abs_tests),
                                      app_root: config.project_root).start
        end
      rescue StandardError
        clients.each(&:quit)
        raise
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
            progress.tick
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
    # ONE mutant is {DaemonClient}'s business: it respawns and answers `"error"`.
    # Nothing is caught here on purpose — anything reaching this far is either
    # {DaemonBootError}, which must end the run, or a defect, which must stay visible.
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
      # JobPlan.coverage_selection, so scores match). :verdict = no_coverage/uncapturable,
      # no fork. No map, or an empty one (build failed) → run the full --test set
      # (fallback, not narrowed).
      sel = coverage_map && !coverage_map.map.empty? && JobPlan.coverage_selection(subject.file, mutation, subject, source, coverage_map)
      r =
        if Parser.parse_string(mutated).errors.any?
          Result.skipped
        elsif sel && sel[0] == :verdict
          sel[1]
        else
          verdict = client.request(
            id: req_id, worker: worker, timeout: config.daemon_timeout || DEFAULT_TIMEOUT,
            payload: { "code" => mutated, "source_file" => File.expand_path(subject.file, config.project_root) },
            tests: sel ? sel[1] : abs_tests
          )
          # A survivor whose line ran at load, as in-process (Runner.run).
          JobPlan.load_verdict(result_for(verdict), subject.file, mutation, subject, source, coverage_map)
        end
      r.with(subject: subject, mutation: mutation, id: id)
    end

    # The boot config the daemon needs to boot the app once: where to boot, the
    # --require files to load after it, the test load roots (so
    # `require "test_helper"` resolves in every fork), framework, and whether this
    # is Rails.
    #
    # @param config [Mutineer::Config] the run config.
    # @param abs_tests [Array<String>] absolute --test paths.
    # @param coverage [Boolean] whether this daemon builds the coverage map.
    # @param db_role [String, nil] "prepare" (copy databases on command),
    #   "worker" (lock only), or nil to pick from `coverage`.
    # @return [Hash] the boot config shipped to the daemon.
    def self.boot_config(config, abs_tests, coverage: false, db_role: nil)
      {
        project_root: config.project_root,
        boot: File.expand_path(config.boot || "config/environment", config.project_root),
        # Required after the boot, as in-process (Runner.execute); also part of
        # the coverage digest.
        require_paths: config.require_paths.map { |f| File.expand_path(f, config.project_root) },
        load_paths: JobPlan.test_load_roots(abs_tests),
        cache_dir: File.expand_path(config.cache_dir, config.project_root),
        source_dirs: JobPlan.source_dirs(config), # so the daemon can sweep orphan mutant temps
        framework: config.framework,
        rails: config.rails,
        # Schema for per-worker DB isolation. Sent when present; the daemon loads
        # it over a worker's copy of the test DB only when that copy is out of date.
        schema: schema_path(config),
        # Coverage narrowing. Only the short-lived map-building daemon starts
        # Coverage (before boot); worker daemons boot with it OFF (no wasted
        # instrumentation/memory across every mutant fork). `sources`/`tests` are the
        # map-build inputs.
        coverage: coverage,
        # "prepare" copies worker databases when asked. "worker" only locks.
        # A direct client that omits this provisions at boot instead.
        db_role: db_role || (coverage ? "prepare" : "worker"),
        # The map-building daemon's capture limit (--capture-timeout); nil = default.
        capture_timeout: config.capture_timeout,
        sources: config.sources.map { |s| File.expand_path(s, config.project_root) },
        tests: abs_tests
      }
    end

    # Absolute path to the app's `db/schema.rb` if it exists, else nil. Each worker
    # DB starts as a copy of the test DB; the daemon loads this file over the copy
    # when the copy's schema differs. `structure.sql` apps get nil and keep the
    # copy as it is.
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
    private_class_method :run_serial, :run_parallel, :job_result, :schema_path, :result_for,
                         :prepare_run, :coverage_map_from_client
  end
end
