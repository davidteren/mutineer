# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "parser"
require_relative "project"
require_relative "result"
require_relative "statement_lines"
require_relative "isolation"
require_relative "minitest_integration"
require_relative "test_runners"
require_relative "coverage_map"
require_relative "changed_lines"
require_relative "mutator_registry"
require_relative "worker_pool"
require_relative "progress"
require_relative "mutant_id"
require_relative "project_path"
require_relative "file_swap"
require_relative "external_backend"
require_relative "daemon_backend"
require "set"

module Mutineer
  # Orchestrates one mutation end-to-end: apply it textually, validate the
  # result, select its covering test files from the coverage map, then run only
  # those against the mutated source in an isolated child process (strategy
  # whole-file reload via `load`).
  #
  # The source file path is passed explicitly because Mutation carries only byte
  # offsets, not its file. Coverage-map selection replaces a hardcoded test file:
  # a mutation whose line no test exercises is :no_coverage (no fork); otherwise
  # exactly the covering test files run in the child.
  class Runner
    # Full orchestration: resolve operators, discover subjects, build the
    # coverage map, run every mutation, and aggregate. Returns
    # [AggregateResult, source_map, extras], where extras is the hash
    # {.collect_jobs} returns (`:legacy_ignore_matches`, `:id_map`), unchanged.
    # The CLI then reports + applies the exit code; the integration test asserts
    # directly on the AggregateResult.
    #
    # The parent process `require`s each source file so its classes exist; forked
    # children inherit them, so a covering test file's own require_relative of the
    # source is a no-op and does not clobber the mutated `load` (spec §7).
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [Array(Mutineer::AggregateResult, Hash<String, String>, Hash)] aggregate,
    #   source map, and run extras.
    def self.execute(config)
      operator_classes = MutatorRegistry.resolve(config.operators || MutatorRegistry::DEFAULT_NAMES)

      # External backend: run the suite as a subprocess in the app's own runtime.
      # It does no in-process boot/require or coverage build, so branch before any
      # of that. The in-process path below is untouched.
      return execute_external(config, operator_classes) if config.test_command

      # Daemon backend: boot the app ONCE in a persistent subprocess under the
      # app's bundle and fork per mutant. Tool-side we only discover jobs + build
      # payloads (Prism), so branch before any in-process boot.
      return DaemonBackend.execute(config, operator_classes) if config.daemon

      # Boot mode: require the boot file ONCE so the app env (e.g. Rails) is booted
      # in the parent and inherited by every fork. Do NOT manually require the
      # sources. Under Zeitwerk a manual require of an autoloadable file raises;
      # the booted env autoloads them, and subject discovery is a static Prism
      # parse that needs nothing loaded. Standalone mode requires the sources as
      # before so their classes exist for the children to inherit.
      if config.boot
        # Under --rails an unset RAILS_ENV boots development, where the test
        # suite is not loaded. Coverage comes back empty and EVERY mutant is
        # falsely reported no_coverage (score N/A, exit 0). Default it to test.
        ensure_rails_env(config)

        # Coverage instruments only files loaded AFTER it starts. Start it BEFORE
        # the boot require so the entire app loaded during boot is instrumented;
        # forked children then measure each test's coverage delta against it.
        require "coverage"
        Coverage.start(lines: true) unless Coverage.running?
        require File.expand_path(config.boot, config.project_root)
      else
        config.sources.each { |f| require File.expand_path(f, config.project_root) }
      end
      config.require_paths.each { |f| require File.expand_path(f, config.project_root) }

      if config.boot
        # Rails/Minitest test files do `require "test_helper"`, which needs the
        # test root on $LOAD_PATH (`bin/rails test` adds it). Prepend each test
        # file's helper root here in the parent so loading them in the fork
        # children (both coverage capture and per-mutant) resolves.
        boot_tests = config.tests.map { |t| File.expand_path(t, config.project_root) }
        test_load_roots(boot_tests).each { |d| $LOAD_PATH.unshift(d) unless $LOAD_PATH.include?(d) }

        # Boot mode now uses coverage selection too: capture each test's coverage
        # by forking the booted parent, then select covering tests per mutant.
        coverage_map = CoverageMap.new(
          source_paths: config.sources, test_paths: config.tests,
          cache_dir: File.expand_path(config.cache_dir, config.project_root), project_root: config.project_root,
          load_paths: config.load_paths, framework: config.framework,
          boot_path: File.expand_path(config.boot, config.project_root),
          verbose: config.verbose,
          capture_timeout: config.capture_timeout || CoverageMap::DEFAULT_CAPTURE_TIMEOUT
        ).build_via_fork(after_fork: (config.rails ? -> { reconnect_active_record } : nil))
      else
        # As in boot mode, and with lib first as `rake test` does.
        test_roots = test_load_roots(config.tests.map { |t| File.expand_path(t, config.project_root) })
        libs = config.load_paths.map { |p| File.expand_path(p, config.project_root) }
        $LOAD_PATH.unshift(*(libs + test_roots).uniq.reject { |d| $LOAD_PATH.include?(d) })
        # Relative, so the cache digest does not depend on the checkout path.
        rel_roots = test_roots.map { |d| Pathname(d).relative_path_from(File.expand_path(config.project_root)).to_s }
        coverage_map = CoverageMap.new(
          source_paths: config.sources, test_paths: config.tests,
          cache_dir: File.expand_path(config.cache_dir, config.project_root), project_root: config.project_root,
          load_paths: config.load_paths + rel_roots, framework: config.framework,
          capture_timeout: config.capture_timeout || CoverageMap::DEFAULT_CAPTURE_TIMEOUT
        ).build_or_load
      end
      abort_if_unclean!(coverage_map)

      # Collect every (subject, mutation) up front so the pool can fan them out.
      jobs, ignored_results, source_map, extras = collect_jobs(config, operator_classes)

      jobs = filter_since(jobs, source_map, config) if config.since

      # Whole-file reload writes mutineer_mutant*.rb into each source dir (so
      # require_relative resolves). A SIGKILL'd child skips the tempfile's
      # ensure-unlink, orphaning it. `ensure` is unreliable vs SIGKILL, so the
      # PARENT sweeps each source dir before and after the run. Orphans are
      # impossible after a normal run.
      dirs = source_dirs(config)
      sweep_orphans(dirs)

      strategy = config.strategy
      # Fail-fast must be serial: a parallel stop_when fires on the first survivor
      # by wall-clock, not input order, so the survivor set would diverge from
      # --jobs 1 (daemon already forces serial for the same reason).
      jobs_n = config.fail_fast ? 1 : config.jobs
      results =
        begin
          framework = config.framework
          stop_when = config.fail_fast ? ->(r) { r.survived? } : nil
          progress  = Progress.new(jobs.size)
          bare = WorkerPool.new(jobs_n).run(jobs, stop_when: stop_when,
                                                  on_result: ->(_r) { progress.tick }) do |subject, mutation|
            run(mutation, source_file: subject.file, coverage_map: coverage_map,
                subject: subject, strategy: strategy, rails: config.rails, framework: framework,
                timeout: config.timeout || Isolation::DEFAULT_TIMEOUT, matrix: config.matrix)
          end
          # The bare Results carry only status (Subjects hold live AST nodes that
          # do not marshal); reattach subject+mutation+id in the parent, in order.
          # filter_map drops nils for jobs --fail-fast left unscheduled.
          share_tests(bare.each_with_index.filter_map do |r, i|
            r = unreported_row(r) if r && config.matrix
            r&.with(subject: jobs[i][0], mutation: jobs[i][1], id: jobs[i][2])
          end)
        ensure
          sweep_orphans(dirs)
        end

      [AggregateResult.new(results + ignored_results), source_map, extras]
    end

    # A `--matrix` error that carries no {Kills} row (the worker crashed, or its
    # result was lost) gets an empty, incomplete row: its tests never reported,
    # so a blind test may have killed it, and the report must say so.
    #
    # @param result [Mutineer::Result] a worker's result.
    # @return [Mutineer::Result]
    def self.unreported_row(result)
      return result unless result.error? && result.kills.nil?

      result.with(kills: Kills.new(killed_by: [], ran: [], complete: false))
    end

    # Collect every (subject, mutation, id) up front so a backend can run them.
    # A mutant the user marked known-equivalent (inline disable-line comment or
    # .mutineer.yml ignore id) is classified :ignored here and NEVER run. It is
    # removed from the killed+survived denominator so a strong file reaches 100%.
    # The id is computed per subject (occurrence needs the full list), keyed on
    # the file path relative to config.project_root, and carried on every job so
    # the parent can reattach it after the run. Shared by the in-process,
    # external, and daemon backends so job selection can never drift.
    #
    # Each mutant also gets its old-format id ({MutantId.legacy_for}), so an ignore
    # entry stored before ids carried the path still suppresses it. Prints nothing:
    # the extras hash returns, as data, `legacy_ignore_matches` (each old-format
    # ignore entry that matched a mutant through its old-format id => one
    # `{id:, file:, subject:}` hash per matched mutant, in collection order: its
    # new id, its project-relative file and its subject's qualified name;
    # recorded even when a new id is also listed, since the old entry still
    # over-matches other files) and `id_map` (every new id => its old-format id).
    #
    # Subjects sharing a qualified name in one file (two owner-less `def index`
    # in two DSL blocks) get a per-file ordinal in discovery order, so their ids
    # differ; the first one's ordinal is 0 and leaves its id unchanged.
    #
    # @param config [Mutineer::Config] run configuration.
    # @param operator_classes [Array<Class>] resolved operators.
    # @return [Array(Array, Array<Result>, Hash<String,String>, Hash{Symbol => Hash})]
    #   jobs, ignored, source_map, and extras (`:legacy_ignore_matches`, `:id_map`).
    def self.collect_jobs(config, operator_classes)
      source_map = {}
      disabled_map = {}
      id_paths = {}
      # [file, qualified_name] => { declaration offset => ordinal }: keyed by the
      # declaration, so the same file discovered twice (two path spellings) reuses
      # its ordinal instead of minting a second id for the same mutant.
      name_decls = Hash.new { |h, k| h[k] = {} }
      ignore_set = config.ignore.to_set
      jobs = []
      ignored_results = []
      legacy_ignore_matches = {}
      id_map = {}
      Project.discover(config.sources, only: config.only).each do |subject|
        source = (source_map[subject.file] ||= File.read(subject.file))
        disabled = (disabled_map[subject.file] ||= suppress_map(source, subject.file))
        mutations = operator_classes.flat_map { |klass| klass.new.mutations_for(subject, source) }
        id_path = (id_paths[subject.file] ||= ProjectPath.relative(subject.file, config.project_root))
        decls = name_decls[[id_path, subject.qualified_name]]
        ordinal = (decls[subject.def_node.location.start_offset] ||= decls.size)
        ids = MutantId.for_subject(subject, source, mutations, path: id_path, subject_ordinal: ordinal)
        legacy_ids = MutantId.legacy_for_subject(subject, source, mutations)
        lines = mutations.map { |m| source.byteslice(0, m.start_offset).count("\n") + 1 }
        keys = result_keys(mutations, source, lines)
        # A repeat of an earlier edit on the same line is dropped (#159),
        # separately among the run and the ignored mutants, so an ignored copy
        # never hides a copy that should run. A dropped copy records nothing.
        seen = { run: Set.new, ignored: Set.new }
        mutations.each_with_index do |mutation, i|
          id = ids[i]
          legacy = legacy_ids[i]
          ignored = suppressed?(mutation.operator, lines[i], [id, legacy], disabled, ignore_set)
          next unless seen[ignored ? :ignored : :run].add?(keys[i])

          id_map[id] = legacy
          # An old entry still over-matches other files even when the new id is
          # listed too, so every old-entry match is reported for migration.
          if ignore_set.include?(legacy)
            (legacy_ignore_matches[legacy] ||= []) << { id: id, file: id_path, subject: subject.qualified_name }
          end
          if ignored
            ignored_results << Result.ignored.with(subject: subject, mutation: mutation, id: id)
          else
            jobs << [subject, mutation, id]
          end
        end
      end
      [jobs, ignored_results, source_map, { legacy_ignore_matches: legacy_ignore_matches, id_map: id_map }]
    end

    # One key per mutation; two mutations share a key exactly when they are
    # the same operator on the same line and give the same mutated source (one
    # edit, #159). The caller drops a repeat after ids are assigned. Only a
    # group of same-operator, same-line mutations can repeat, so only those
    # build a key from their text: the span from the group's earliest start to
    # its latest end, digested. Every other mutation gets a key of its own.
    #
    # @param mutations [Array<Mutineer::Mutation>] one subject's mutations.
    # @param source [String] the full, unmutated source.
    # @param lines [Array<Integer>] each mutation's line.
    # @return [Array<Object>] one key per mutation, in order.
    def self.result_keys(mutations, source, lines)
      keys = Array.new(mutations.size) { |i| i }
      mutations.each_index.group_by { |i| [mutations[i].operator, lines[i]] }.each_value do |group|
        next if group.size < 2

        from = group.map { |i| mutations[i].start_offset }.min
        to = group.map { |i| mutations[i].end_offset }.max
        group.each do |i|
          m = mutations[i]
          span = "#{source.byteslice(from...m.start_offset)}#{m.replacement}#{source.byteslice(m.end_offset...to)}"
          keys[i] = [m.operator, lines[i], Digest::SHA256.digest(span)]
        end
      end
      keys
    end

    # External backend orchestration. Runs each mutant's whole-file mutation on
    # disk (crash-safe swap) and executes the user's --test-command as a subprocess
    # in the app's own runtime. Serial by construction (one shared DB, no
    # per-worker isolation yet). No coverage narrowing: every mutant runs the full
    # --test set; the score is therefore an upper bound and not comparable to an
    # in-process run (the CLI discloses this).
    #
    # @param config [Mutineer::Config] run configuration (test_command set).
    # @param operator_classes [Array<Class>] resolved operators.
    # @return [Array(Mutineer::AggregateResult, Hash<String,String>, Hash)] aggregate,
    #   source map, and the {.collect_jobs} extras.
    def self.execute_external(config, operator_classes)
      abs_tests = config.tests.map { |t| File.expand_path(t, config.project_root) }
      sources   = config.sources.map { |s| FileSwap.canonical_path(File.expand_path(s, config.project_root)) }
      dirs      = sources.map { |s| File.dirname(s) }.uniq

      # Own every source before healing leftovers or reading bytes for mutation.
      # A backup file alone is not ownership; flock is. Canonical paths so
      # symlink aliases of one inode share one lock, independent of cache_dir.
      FileSwap.owning(sources) do
        # Heal any file a prior hard-killed run left mutated BEFORE reading source.
        # collect_jobs computes mutation offsets/ids from the on-disk bytes, so a
        # still-mutated file would yield garbage offsets against the later-healed
        # source. Heal first, then discover jobs from the clean tree.
        FileSwap.restore_orphans(dirs)

        jobs, ignored_results, source_map, extras = collect_jobs(config, operator_classes)
        jobs = filter_since(jobs, source_map, config) if config.since

        # Nothing to mutate: return before the smoke check, which runs the whole
        # --test set to calibrate a timeout no mutant would use (#76).
        next [AggregateResult.new(ignored_results), source_map, extras] if jobs.empty?

        # Calibrate the per-mutant timeout from the clean run (a real suite far
        # outlasts the 10s in-process fork budget), and abort if it is not green.
        # 3x the clean run, floor 30s, ceiling 300s: a heuristic. The floor covers
        # a fast suite; the ceiling bounds a hung mutant (infinite loop) so a
        # handful cannot stall a serial run for ~45min on a slow suite.
        smoke_elapsed = ExternalBackend.smoke_check!(config.test_command, abs_tests)
        timeout = [[smoke_elapsed * 3, 30].max, 300].min.ceil

        results = []
        progress = Progress.new(jobs.size)
        begin
          jobs.each do |subject, mutation, id|
            r = run_external(subject, mutation, config.test_command, abs_tests,
                             timeout: timeout, verbose: config.verbose)
            results << r.with(subject: subject, mutation: mutation, id: id)
            progress.tick
            break if config.fail_fast && r.survived? # stop at the first survivor
          end
        ensure
          FileSwap.restore_orphans(dirs)
        end

        [AggregateResult.new(results + ignored_results), source_map, extras]
      end
    end

    # Runs one mutant through the external backend: apply the whole-file mutation
    # on disk, run the command, restore. An invalid (non-reparsing) mutant would
    # fail to load and score a false `killed`, so skip it tool-side (Prism, already
    # cheap) and never write the file, preserving the `skipped` verdict the
    # in-process path gives at the pre-fork check.
    #
    # @return [Mutineer::Result] verdict for this mutant.
    def self.run_external(subject, mutation, command, abs_tests, timeout:, verbose:)
      source  = File.read(subject.file)
      mutated = mutation.apply(source)
      return Result.skipped if Parser.parse_string(mutated).errors.any?

      FileSwap.with(subject.file, mutated) do
        ExternalBackend.run(command, abs_tests, timeout: timeout, verbose: verbose)
      end
    end

    # Aborts the run when coverage capture saw a red unmutated suite. Scoring
    # those results would treat existing assertion failures as killed mutants.
    #
    # @param coverage_map [Mutineer::CoverageMap] the built or loaded map.
    # @return [void]
    # @raise [Mutineer::SmokeCheckError] when any captured test failed clean,
    #   or when no test recorded coverage and a capture failed.
    def self.abort_if_unclean!(coverage_map)
      if coverage_map.map.empty? && coverage_map.failed_test_files.any?
        raise SmokeCheckError, "no test recorded coverage, and capture failed for #{coverage_map.failed_test_files.join(', ')}"
      end

      files = coverage_map.failed_clean_tests
      return if files.empty?

      raise SmokeCheckError,
            "the unmutated suite is not green (#{files.join(', ')}) — " \
            "#{ExternalBackend.generic_env_hint}."
    end

    # Coverage-based test selection, shared by the in-process ({run}) and daemon
    # paths so both narrow identically (score parity). Returns
    # `[:run, abs_test_paths]` when some test covers the mutant's line, or
    # `[:verdict, Result]` (no_coverage / uncapturable) when none do. A line
    # Ruby does not count (a later line of a multi-line statement) uses the
    # tests that ran the statement that holds it ({StatementLines}), unless the
    # mutant sits in code of that statement that runs only sometimes.
    #
    # An empty selection is `:uncapturable` (not `:no_coverage`) when the
    # mutant's enclosing method body got coverage from no *successful* capture but
    # a sibling test failed to capture: the coverage was lost, not absent. Both are
    # excluded from the score denominator, so this distinction is reporting-only
    # and never changes the daemon-vs-in-process score.
    #
    # @param source_file [String] the mutated source file path.
    # @param mutation [Mutineer::Mutation] the mutation (for its line offset).
    # @param subject [Mutineer::Subject, nil] the subject (for its method body range).
    # @param source [String] the original source text.
    # @param coverage_map [Mutineer::CoverageMap] the built/loaded coverage map.
    # @return [Array(Symbol, Object)] `[:run, Array<String>]` or `[:verdict, Result]`.
    def self.coverage_selection(source_file, mutation, subject, source, coverage_map)
      line   = source.byteslice(0, mutation.start_offset).count("\n") + 1
      chosen = coverage_map.tests_for(source_file, line)
      if chosen.empty? && subject
        # A multi-line statement has a count on one of its lines only.
        lines = StatementLines.for(subject.def_node, source, mutation.start_offset)
        chosen = lines.flat_map { |l| coverage_map.tests_for(source_file, l) }.uniq
      end
      if chosen.empty?
        # Method BODY range, not the whole def: the def/end lines are "covered" at
        # class-load even when the body never runs (body_loc is the statements' span).
        loc   = subject&.body_loc
        range = loc ? (loc.start_line..loc.end_line) : (line..line)
        return [:verdict, coverage_map.method_uncapturable?(source_file, range) ? Result.uncapturable : Result.no_coverage]
      end

      [:run, chosen.map { |t| File.expand_path(t, coverage_map.project_root) }]
    end

    # Map each line number to :all or a set of operator symbols, using
    # inline `# mutineer:disable-line [ops]` markers (RuboCop semantics: the marker
    # sits on the same physical line as the code it silences). A bare marker
    # disables every operator on that line; `disable-line a, b` only the listed
    # operators. Block-form disable/enable ranges are intentionally not supported.
    # Only a real `#` comment counts: Prism lists the comments, so the marker
    # text inside a string, heredoc or regex silences nothing (#158).
    def self.suppress_map(source, file)
      map = {}
      Parser.comments(source).grep(Prism::InlineComment).each do |comment|
        line = comment.location.start_line
        next unless (m = comment.slice.match(/#\s*mutineer:disable-line(?:\s+([\w,\s]+))?/))

        ops = m[1]&.split(",")&.map(&:strip)&.reject(&:empty?)
        # Only spaces or commas after the marker (e.g. `disable-line  -- why`)
        # is a bare marker, not an empty list that silences nothing.
        ops = nil if ops&.empty?
        unknown = ops.to_a.reject { |o| MutatorRegistry::ALL.key?(o) }
        unknown.each do |o|
          warn "mutineer: unknown operator #{o.inspect} in #{file}:#{line} " \
               "(known: #{MutatorRegistry::ALL.keys.join(', ')}); write a reason after --"
        end
        map[line] = ops ? ops.map(&:to_sym).to_set : :all
      end
      map
    end

    # True when this mutant is suppressed: its line bears a disable-line marker
    # (bare, or scoped to its operator), OR its new or old-format id is in the
    # config ignore list. Checked at job-build time so a suppressed mutant is
    # never forked.
    #
    # @param ids [Array<String>, String] the mutant's new id and its old-format
    #   id, or a single id (the pre-#126 call shape).
    def self.suppressed?(operator, line, ids, disabled, ignore_set)
      return true if Array(ids).any? { |id| ignore_set.include?(id) }

      case (entry = disabled[line])
      when :all then true
      when Set  then entry.include?(operator)
      else false
      end
    end

    # --since: keep only jobs whose mutation lands on a line changed since the git
    # ref. Composes with coverage selection (it only narrows the job list; each
    # surviving mutant still goes through Runner.run's coverage check). A file with
    # no changed lines (absent from the diff) contributes no jobs. Line is computed
    # exactly as Runner.run does, from the already-read source in source_map.
    def self.filter_since(jobs, source_map, config)
      changed = ChangedLines.for(ref: config.since, files: config.sources,
                                 project_root: config.project_root)
      jobs.select do |subject, mutation|
        source = source_map[subject.file]
        line = source.byteslice(0, mutation.start_offset).count("\n") + 1
        abs = File.expand_path(subject.file, config.project_root)
        changed.fetch(abs, []).include?(line)
      end
    end

    # For each test file, the directory to add to $LOAD_PATH so its
    # `require "test_helper"` (or spec_helper) resolves: the nearest ancestor
    # holding that helper, plus the file's own dir as a fallback.
    def self.test_load_roots(test_files)
      test_files.flat_map do |f|
        dir = File.dirname(f)
        root = nil
        loop do
          if File.exist?(File.join(dir, "test_helper.rb")) || File.exist?(File.join(dir, "spec_helper.rb"))
            root = dir
            break
          end
          parent = File.dirname(dir)
          break if parent == dir

          dir = parent
        end
        [root, File.dirname(f)].compact
      end.uniq
    end

    # When --rails is on and RAILS_ENV is unset, default it to "test" (and say so)
    # before the app boots. Otherwise it boots development and nothing is measured.
    # An explicitly-set RAILS_ENV is always respected.
    def self.ensure_rails_env(config)
      return unless config.rails
      return unless ENV["RAILS_ENV"].nil? || ENV["RAILS_ENV"].empty?

      ENV["RAILS_ENV"] = "test"
      warn "[mutineer] RAILS_ENV was unset; defaulting to 'test' for --rails."
    end

    # The unique absolute directories holding the sources. Sweep target for both
    # orphan mechanisms (in-process mutant tempfiles and external backup files),
    # and shipped to the daemon via {DaemonBackend.boot_config} so it can sweep too.
    # Shared so the path-expansion rule cannot drift between the paths.
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [Array<String>] unique absolute source directories.
    def self.source_dirs(config)
      config.sources.map { |f| File.dirname(File.expand_path(f, config.project_root)) }.uniq
    end

    # Removes stale mutant tempfiles from the given directories. The daemon writes a
    # differently-named temp, so {DaemonBackend} passes its glob when it has to sweep
    # tool-side (nothing boots on an empty run, so the daemon's own sweep never runs).
    #
    # @param dirs [Array<String>] directories to sweep.
    # @param glob [String] filename pattern to remove.
    # @return [void]
    def self.sweep_orphans(dirs, glob = "mutineer_mutant*.rb")
      dirs.each do |dir|
        Dir.glob(File.join(dir, glob)).each do |f|
          File.unlink(f) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
    end

    # Runs a single mutation through isolation.
    #
    # @param mutation [Mutineer::Mutation] mutation to run.
    # @param source_file [String] source file path.
    # @param coverage_map [Mutineer::CoverageMap, nil] coverage map.
    # @param subject [Mutineer::Subject, nil] subject for surgical strategy.
    # @param strategy [String] mutation strategy.
    # @param timeout [Integer] child timeout in seconds.
    # @param rails [Boolean] whether Rails reconnect handling is enabled.
    # @param framework [String] test framework name.
    # @param matrix [Boolean] a `--matrix` run: run every covering test and
    #   attach the {Kills} row, with project-relative test files.
    # @return [Mutineer::Result] mutant result.
    def self.run(mutation, source_file:, coverage_map: nil, subject: nil, strategy: "reload",
                 timeout: Isolation::DEFAULT_TIMEOUT, rails: false, framework: "minitest", matrix: false)
      source  = File.read(source_file)
      mutated = mutation.apply(source)

      # Validity rule: a mutant that does not re-parse is skipped before forking.
      return Result.skipped if Parser.parse_string(mutated).errors.any?

      # Coverage selection (both standalone and boot mode): a mutation on a line
      # no test exercises is :no_coverage (no fork); otherwise exactly the
      # covering test files run in the child. Shared with the daemon path so both
      # narrow identically (score parity).
      kind, payload = coverage_selection(source_file, mutation, subject, source, coverage_map)
      return payload if kind == :verdict

      abs_tests = payload

      result = Isolation.run(timeout: timeout, channel: matrix) do |channel|
        # Forking inherits the parent's live DB connection; sharing one socket
        # across processes corrupts it. Drop it so AR reconnects per child.
        reconnect_active_record if rails
        if strategy == "redefine"
          Isolation.apply_surgical(mutation, subject, source)
        else
          Isolation.apply_whole_file(mutated, source_file)
        end
        if channel
          # --matrix: every covering test runs, and each outcome goes to the parent.
          TestRunners.for(framework).run(abs_tests, record_to: channel)
        else
          # One failing test already kills the mutant, so the child stops there.
          TestRunners.for(framework).run(abs_tests, stop_at_first_failure: true)
        end
      end
      relative_kills(result, coverage_map.project_root)
    end

    # Rewrites the test files of a result's {Kills} row relative to the project
    # root, the form the coverage map and the report use. A result without a
    # row comes back unchanged.
    #
    # @api private
    # @param result [Mutineer::Result] a mutant result.
    # @param root [String] project root.
    # @return [Mutineer::Result]
    def self.relative_kills(result, root)
      return result unless (kills = result.kills)

      paths = {}
      rel = lambda do |tests|
        tests.map { |file, name, id| [(paths[file] ||= ProjectPath.relative(file, root)), name, id] }.uniq.sort
      end
      result.with(kills: kills.with(killed_by: rel.call(kills.killed_by), ran: rel.call(kills.ran)))
    end

    # Makes every {Kills} row refer to one shared, frozen array per test. Each
    # row arrives with its own copy of every test it ran, and a large matrix
    # (thousands of mutants times hundreds of tests) would otherwise hold that
    # many copies. Results without a row come back unchanged.
    #
    # A test is its file and its id. The name is display data and can differ
    # between mutants (an RSpec example worded from its matcher reads
    # differently under each mutant), so every row gets the name the first
    # mutant reported, and one example stays one test.
    #
    # @api private
    # @param results [Array<Mutineer::Result>] mutant results.
    # @return [Array<Mutineer::Result>]
    def self.share_tests(results)
      shared = {}
      share = lambda do |tests|
        tests.map { |file, name, id| shared[[file, id]] ||= [file, name, id].map { |s| -s }.freeze }.uniq.sort.freeze
      end
      results.map do |r|
        next r unless (kills = r.kills)

        r.with(kills: kills.with(killed_by: share.call(kills.killed_by), ran: share.call(kills.ran)))
      end
    end

    # Reconnects ActiveRecord in a forked child when available.
    #
    # @api private
    # @return [void]
    def self.reconnect_active_record
      return unless defined?(ActiveRecord::Base)

      base = ActiveRecord::Base
      # Clearing connections here drops an open transactional-fixture
      # transaction, so the test loses its fixture rows and fails. Skip the clear
      # when a transaction is open; otherwise clear (per-fork write-safety).
      return if fixture_transaction_open?(base)

      base.connection_handler.clear_all_connections!
    rescue StandardError
      nil
    end
    private_class_method :reconnect_active_record

    # Pure, injectable predicate: true when a transactional-fixture transaction is
    # already open on the connection. Keys off open_transactions so it is correct
    # whenever the transaction exists, regardless of when it opened. Any probe
    # error degrades safe to false -> caller clears (existing behaviour).
    def self.fixture_transaction_open?(base)
      pool = base.connection_pool
      pool.active_connection? && base.connection.open_transactions.positive?
    rescue StandardError
      false
    end
    private_class_method :fixture_transaction_open?
  end
end
