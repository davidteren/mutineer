# frozen_string_literal: true

require "optparse"
require "open3"
require_relative "version"
require_relative "config"
require_relative "parser"
require_relative "project"
require_relative "pairing"
require_relative "changed_lines"
require_relative "runner"
require_relative "reporter"
require_relative "kill_matrix"
require_relative "baseline"
require_relative "mutator_registry"

module Mutineer
  # Command-line entry point. `start` is the single public method called by
  # bin/mutineer; it parses argv, acts, and exits with a pinned code.
  #
  # Exit codes:
  #   0  success / requested output (--version, --help, score >= threshold)
  #   1  survivors below threshold, or a runtime error
  #   2  usage / flag error (unknown subcommand, invalid flag, unknown operator,
  #      out-of-range threshold)
  class CLI
    # Command-line usage banner.
    BANNER = <<~USAGE
      Usage: mutineer [options] <command> [args]

      Commands:
        run [options] <source...> --test <test> [--test <test>...]
                                                     Mutate, run, and report
        run --dry-run [options] <source...>          Print candidate mutations only

      Run options:
        --test FILE          Test file covering the sources (one per flag; repeat it)
        --operators LIST     Comma-separated operator names (default: Tier 1 set)
        --threshold FLOAT    Fail (exit 1) when score < FLOAT (default: 0 = off)
        --baseline FILE      Fail (exit 1) on NEW survivors / score drop vs a prior
                             --format json run (CI delta gate)
        --baseline-epsilon FLOAT  Score-drop tolerance for --baseline (default: 0)
        --only NAME          Restrict to one fully-qualified subject
        --since REF          Only mutate lines changed since git REF (e.g. origin/main)
        --no-since           Disable diff scoping (a typed no beats a .mutineer.yml since:)
        --jobs N             Parallel worker count (default: processor count);
                             --test-command, --fail-fast, or --rails
                             without --daemon forces 1
        --strategy NAME      reload (whole-file) or redefine (surgical); default: reload
        --framework NAME     minitest or rspec (default: auto-detect from --test names)
        --boot FILE          Require FILE once in the parent to boot the app env, then
                             fork per mutant (Rails apps; requires --test)
        --rails              Boot config/environment; without --daemon, defaults to
                             redefine and serial execution
        --test-command CMD   Run the target suite in the app's own runtime as a
                             subprocess (for apps on Ruby < 3.4). CMD must contain
                             %{files}. Scrubs Mutineer Ruby PATH pins; set RAILS_ENV
                             on the mutineer command (not as KEY=val inside CMD)
        --daemon             Boot the app ONCE in a persistent daemon and fork per
                             mutant, with per-worker DB isolation so --jobs N is safe
                             under Rails (needs --rails/--boot; not with --test-command)
        --format human|json|html  Report format (default: human)
        --output FILE        Write the report to FILE instead of stdout
        --dry-run            List mutations without executing
        --fail-fast          Stop at the first surviving mutant
        --matrix             Run every covering test for each mutant and report which
                             tests kill it, with blind and redundant tests (in-process
                             only; not with --daemon, --test-command or --fail-fast)
        --verbose            Surface the real error when a fork capture fails (alias: --debug)

      Options:
        --list-operators  List available operators (default vs optional) and exit
        --version         Print version and exit
        --help            Print this help and exit
    USAGE

    # Parses arguments, executes the command, and exits.
    #
    # @param argv [Array<String>] raw command-line arguments.
    # @return [void]
    def self.start(argv)
      # The CLI layer holds only the fields the user typed, so Config.resolve
      # can tell a typed `false`/`nil` from an absent flag by whether the key exists.
      opts = {}
      show_operators = false

      parser = OptionParser.new do |o|
        o.banner = BANNER
        o.on("--version") do
          puts Mutineer::VERSION
          exit 0
        end
        o.on("--help") do
          puts BANNER
          exit 0
        end
        o.on("--list-operators") { show_operators = true }
        o.on("--dry-run") { opts[:dry_run] = true }
        o.on("--fail-fast") { opts[:fail_fast] = true }
        o.on("--matrix") { opts[:matrix] = true }
        o.on("--only NAME") { |v| opts[:only] = v }
        o.on("--since REF") { |v| opts[:since] = Config.parse(:since, v) }
        # A typed "no" must beat a .mutineer.yml `since:` key: the key is present
        # with a nil value, and nil is a value.
        o.on("--no-since") { opts[:since] = nil }
        o.on("--test FILE") { |v| (opts[:tests] ||= []) << v }
        o.on("--operators LIST") do |v|
          opts[:operators] = Config.parse(:operators, v.split(",").map(&:strip))
        end
        o.on("--threshold FLOAT") { |v| opts[:threshold] = Config.parse(:threshold, v) }
        o.on("--jobs N") { |v| opts[:jobs] = Config.parse(:jobs, v) }
        o.on("--strategy STRAT") { |v| opts[:strategy] = Config.parse(:strategy, v) }
        o.on("--framework NAME") { |v| opts[:framework] = Config.parse(:framework, v) }
        o.on("--boot FILE") { |v| opts[:boot] = v }
        o.on("--rails") { opts[:rails] = true }
        o.on("--verbose") { opts[:verbose] = true }
        o.on("--debug") { opts[:verbose] = true } # alias of --verbose
        o.on("--format FORMAT") { |v| opts[:format] = Config.parse(:format, v) }
        o.on("--output FILE") { |v| opts[:output] = v }
        # --baseline-epsilon is CLI-only.
        o.on("--baseline FILE") { |v| opts[:baseline] = v }
        o.on("--baseline-epsilon FLOAT") { |v| opts[:baseline_epsilon] = Config.parse(:baseline_epsilon, v) }
        # Run the target suite as a subprocess in the app's OWN runtime so
        # mutineer (Ruby >= 3.4) can mutation-test apps pinned to an older Ruby.
        o.on("--test-command CMD") { |v| opts[:test_command] = v }
        # Boot the app ONCE in a persistent daemon and fork per mutant, with
        # per-worker DB isolation so --jobs N is safe under Rails.
        o.on("--daemon") { opts[:daemon] = true }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument, Mutineer::ConfigError => e
        warn "mutineer: #{e.message}"
        exit 2
      end

      if show_operators
        list_operators
        exit 0
      end

      if argv.empty?
        puts BANNER
        exit 0
      end

      begin
        file_path = Config.find_file
        file_hash = file_path ? Config.from_file(file_path, defer_operators: opts.key?(:operators)) : {}
        config = Config.resolve(opts, file_hash)
      rescue Mutineer::ConfigError => e
        # The lib layer raises instead of killing the host; the CLI maps a
        # config (usage) error to exit 2.
        warn "mutineer: #{e.message}"
        exit 2
      end

      case argv.first
      when "run"
        warn_config_root_mismatch(file_path, config.project_root) if file_path
        tests_as_sources = argv[1..].grep(%r{(\A|/)(test|spec)/.*_(test|spec)\.rb\z})
        if config.explicit?(:tests) && tests_as_sources.any?
          warn "mutineer: #{tests_as_sources.join(', ')} looks like a test file, not a source. " \
               "--test takes one file; repeat it for each test file (--test a_test.rb --test b_test.rb)"
          exit 2
        end
        # A directory source expands to its **/*.rb files; literal files pass
        # through. Test inference (when --test is omitted) happens in validate!.
        config.sources = Pairing.expand_sources(argv[1..], project_root: config.project_root)
        run(config)
      else
        warn "mutineer: unknown command '#{argv.first}'"
        exit 2
      end
    end

    # Lists available operators.
    #
    # @return [void]
    def self.list_operators
      MutatorRegistry::ALL.each_key do |name|
        state = MutatorRegistry.default?(name) ? "default" : "disabled"
        puts format("%-20s tier %d  %-9s %s",
                    name, MutatorRegistry.tier(name), state, MutatorRegistry::DESCRIPTIONS[name])
      end
    end

    # Runs the requested command after validation.
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.run(config)
      if config.sources.empty?
        warn "mutineer: run requires at least one source file"
        exit 2
      end
      validate!(config)

      config.dry_run ? dry_run(config) : execute(config)
    rescue ArgumentError => e
      # Unknown --operators value surfaces here; no backtrace reaches the user.
      warn "mutineer: #{e.message}"
      exit 2
    rescue SystemCallError => e
      # A missing/unreadable path reaches here as Errno::ENOENT etc. A plain
      # message and usage exit, never a raw backtrace.
      warn "mutineer: #{e.message}"
      exit 2
    rescue SyntaxError => e
      # A syntactically invalid source file surfaces when `require`d; report it
      # cleanly rather than dumping a backtrace.
      warn "mutineer: cannot load source: #{e.message}"
      exit 1
    rescue Mutineer::ParseError => e
      warn "mutineer: error reading: #{e.message}"
      exit 1
    rescue Mutineer::SmokeCheckError => e
      # The unmutated suite is not green under --test-command: a broken
      # environment, not weak tests. Runtime error (exit 1), not usage (exit 2).
      warn "mutineer: #{e.message}"
      exit 1
    rescue Mutineer::ConcurrentRunError => e
      # Another process owns a source file. Runtime error (exit 1), not a
      # backtrace: the working tree is still the other run's responsibility.
      warn "mutineer: #{e.message}"
      exit 1
    rescue Mutineer::DaemonBootError => e
      # The daemon is gone for good, so the run ended rather than scoring the rest
      # against it. A deliberate stop deserves a message, not a raw backtrace.
      warn "mutineer: #{e.message}"
      exit 1
    end

    # Flag validation: every flag/usage failure exits 2, consistent with the
    # taxonomy above. CI can tell "mistyped flag" from "tests too weak."
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.validate!(config)
      # First, so a conflict is reported before another check rewrites the config.
      validate_matrix!(config) if config.matrix
      validate_test_command!(config) if config.test_command

      validate_since!(config) if config.since
      preflight_output!(config.output) if config.output
      preflight_baseline!(config.baseline) if config.baseline

      # When --test is omitted, infer each source's test by convention. Autopair
      # also re-detects framework from inferred tests when --framework was not set.
      autopair!(config) unless config.dry_run

      # Daemon validation runs AFTER autopair so auto-inferred *_spec.rb tests
      # cannot bypass the RSpec rejection (framework would still be minitest if we
      # validated before discovery).
      validate_daemon!(config) if config.daemon

      # Boot mode needs at least one --test file (nothing to select from otherwise).
      if config.boot && config.tests.empty?
        warn "mutineer: --boot/--rails requires at least one --test file"
        exit 2
      end

      validate_paths!(config)
    end

    # --test-command runs the target suite in the app's own runtime. Validate its
    # shape up front (usage errors → exit 2) and force serial execution: each
    # subprocess boots the app and opens its own fixture transaction against the
    # same DB, so --jobs > 1 would corrupt results (fixture-contention hazard).
    # Unlike --rails, this path has NO per-worker DB isolation to opt into, so an
    # explicit --jobs N is forced to 1 rather than honored.
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.validate_test_command!(config)
      if config.test_command.strip.empty?
        warn "mutineer: --test-command must not be empty"
        exit 2
      end
      unless config.test_command.include?("%{files}")
        warn "mutineer: --test-command must contain %{files} (where the --test paths are substituted)"
        exit 2
      end
      if config.boot
        warn "mutineer: --test-command cannot be combined with --boot/--rails " \
             "(the external subprocess boots the app itself)"
        exit 2
      end
      if config.strategy == "redefine"
        warn "mutineer: --test-command supports only --strategy reload " \
             "(surgical redefine needs a shared VM; the subprocess has its own)"
        exit 2
      end
      return unless config.jobs > 1

      warn "[mutineer] --test-command runs serially (no per-worker DB isolation yet); forcing --jobs 1."
      config.jobs = 1
    end

    # --daemon selects the persistent-daemon backend (boot once, fork per mutant,
    # per-worker DB isolation on SQLite). Usage errors exit 2: cannot combine with
    # --test-command; requires --rails or --boot; minitest only; reload strategy only
    # (redefine needs a shared VM surgical path the daemon does not ship).
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.validate_daemon!(config)
      if config.test_command
        warn "mutineer: choose one backend — --daemon and --test-command cannot be combined"
        exit 2
      end
      unless config.rails || config.boot
        warn "mutineer: --daemon needs an app to boot; add --rails (or --boot FILE)"
        exit 2
      end
      if config.framework == "rspec"
        warn "mutineer: --daemon supports only --framework minitest " \
             "(rspec is not implemented on the daemon path yet)"
        exit 2
      end
      return if config.strategy == "reload"

      # --rails defaults strategy to redefine; daemon always whole-file loads.
      warn "[mutineer] --daemon uses --strategy reload " \
           "(redefine is not supported on the daemon path); forcing reload."
      config.strategy = "reload"
    end

    # --matrix runs on the in-process backend and needs every mutant's whole
    # covering run, so a backend that cannot name the failing test, or a run that
    # stops early, is a usage error (exit 2), never a quietly partial matrix.
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.validate_matrix!(config)
      conflict, reason =
        if config.daemon
          [:daemon, "the kill matrix runs on the in-process backend only"]
        elsif config.test_command
          [:test_command, "the external suite reports pass or fail, not which test failed"]
        elsif config.fail_fast
          [:fail_fast, "a fail-fast run is partial, so blind and redundant tests would be wrong"]
        end
      return unless conflict

      warn "mutineer: #{config.origin(:matrix)} cannot be combined with #{config.origin(conflict)} (#{reason})"
      exit 2
    end

    # --since needs a real git repo and a resolvable ref; either failure is a
    # usage error (exit 2) so CI sees "bad invocation," not "tests too weak."
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.validate_since!(config)
      _out, _err, status = Open3.capture3(
        "git", "-C", config.project_root, "rev-parse", "--verify", "--quiet",
        "#{config.since}^{commit}"
      )
      return if status.success?

      inside, = Open3.capture3(
        "git", "-C", config.project_root, "rev-parse", "--is-inside-work-tree"
      )
      msg = inside.strip == "true" ? "unknown git ref: #{config.since}" : "--since requires a git repository"
      warn "mutineer: #{msg}"
      exit 2
    rescue Errno::ENOENT
      warn "mutineer: --since requires git on PATH"
      exit 2
    end

    # Validate path existence up front so a typo is a clean usage error (exit 2),
    # not an Errno::ENOENT backtrace from deep in the run. Flag checks run first
    # so a bad flag still reports the flag, not the missing file.
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.validate_paths!(config)
      missing = (config.sources + config.tests)
                .reject { |p| File.exist?(File.expand_path(p, config.project_root)) }
      return if missing.empty?

      warn "mutineer: no such file: #{missing.join(', ')}"
      exit 2
    end

    # Auto-pair sources to tests by path convention when no --test was given
    # (explicit --test wins). Each source with at least one inferred test on
    # disk joins the run; a source with none is dropped with a one-line stderr
    # warning and the run continues with the rest. Split files for one source
    # are all kept (#87). If every source is dropped: in boot mode the
    # dedicated --boot/--rails-requires-test check reports it; otherwise exit 2
    # with a usage message. The framework is re-detected from the inferred set
    # unless it was set explicitly (a spec-only project loads/reports as rspec).
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.autopair!(config)
      return unless config.tests.empty?

      paired = config.sources.filter_map do |s|
        tests = Pairing.infer_tests(s, project_root: config.project_root, prefer: config.framework)
        [s, tests] unless tests.empty?
      end
      (config.sources - paired.map(&:first)).each do |s|
        warn "[mutineer] no test found by convention for #{s}; skipping"
      end
      config.sources = paired.map(&:first)
      config.tests   = paired.flat_map(&:last).uniq
      config.framework = Config.detect_framework(config.tests) unless config.explicit?(:framework)

      return unless config.sources.empty?
      return if config.boot # let the --boot/--rails-requires-test check report it

      warn "mutineer: no test files found by convention; pass --test or add tests"
      exit 2
    end

    # A missing/unreadable/unparseable baseline is a usage error (exit 2),
    # mirroring --output/--since preflight, so CI sees "bad invocation," not a
    # backtrace mid-run. Validating up front = attempting the load (it raises
    # ConfigError/SystemCallError; the actual diff reloads in execute).
    #
    # @api private
    # @param path [String] baseline file path.
    # @return [void]
    def self.preflight_baseline!(path)
      Baseline.load(path)
    rescue Mutineer::ConfigError, SystemCallError => e
      warn "mutineer: #{e.message}"
      exit 2
    end

    # Preflights an output path.
    #
    # @api private
    # @param path [String] output file path.
    # @return [void]
    def self.preflight_output!(path)
      dir = File.dirname(File.expand_path(path))
      return if File.directory?(dir) && File.writable?(dir)

      reason = File.directory?(dir) ? "directory is not writable" : "no such directory"
      warn "mutineer: cannot write to #{path}: #{reason}"
      exit 2
    end

    # Executes the run command.
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.execute(config)
      if config.tests.empty?
        warn "mutineer: run requires at least one --test file (or use --dry-run)"
        exit 2
      end

      aggregate, source_map, extras = Runner.execute(config)
      warn_legacy_ignore_matches(extras[:legacy_ignore_matches])
      matrix = KillMatrix.new(aggregate.results) if config.matrix
      reporter = Reporter.new(aggregate, source_map, matrix: matrix)

      # Diff the current run against the baseline (preflighted above) by the
      # stable survivor id. The delta is rendered inline (human section / additive
      # json block) and gates exit independently of --threshold. A --since run is
      # scoped: its score covers a different denominator than a full-run baseline,
      # so only the new-survivor half of the gate applies (see Baseline#diff).
      delta = if config.baseline
                Baseline.load(config.baseline).diff(aggregate, epsilon: config.baseline_epsilon,
                                                               scoped: !config.since.nil?,
                                                               id_map: extras[:id_map],
                                                               project_root: config.project_root)
              end
      warn_legacy_baseline if delta&.legacy_matches&.positive?

      # ignore counts old-format entries (one warning each), not the ids they matched.
      legacy_id_matches = { ignore: extras[:legacy_ignore_matches].size,
                            baseline: delta ? delta.legacy_matches : 0 }
      reporter.report(out: $stdout, err: $stderr, threshold: config.threshold,
                      format: config.format, output: config.output, baseline: delta,
                      scoped: !config.since.nil?, legacy_id_matches: legacy_id_matches)

      # Warn (stderr, so it never pollutes json/html) that an external run's score
      # is not comparable to an in-process run: no coverage narrowing (uncovered
      # mutants count as survivors), and an infra failure is scored as a kill
      # (upper bound). Daemon coverage fallback warnings are emitted from the runner
      # only when the map is unavailable, not on every --daemon run.
      if config.test_command
        warn "[mutineer] --test-command score is an upper bound, not comparable to an " \
             "in-process run: no coverage narrowing (uncovered mutants count as survivors) " \
             "and an infra failure is scored as a kill."
      end

      # Nudge toward the opt-in tier-2 operators (human report only: never
      # pollute JSON output).
      if !%w[json html].include?(config.format) && (hint = tier2_hint(config.operators))
        puts hint
      end

      # --baseline and --threshold are independent gates OR'd together.
      # `max` of two 0/1 codes is the OR; usage (2) is handled earlier and wins.
      baseline_exit = delta&.regressed ? 1 : 0
      exit [reporter.exit_code(threshold: config.threshold), baseline_exit].max
    end

    # The tier-2 operators not in the active set, as a one-line hint (or nil when
    # they are all already enabled). `active` nil means the default (Tier-1) set.
    #
    # @param active [Array<String>, nil] active operator names.
    # @return [String, nil] hint text or nil.
    def self.tier2_hint(active)
      active ||= MutatorRegistry::DEFAULT_NAMES
      unused = MutatorRegistry::TIER2_NAMES - active
      return if unused.empty?

      "#{unused.size} tier-2 operators available (#{unused.join(', ')}) — " \
        "enable with --operators <list>."
    end

    # Warns once when the loaded .mutineer.yml sits outside the run directory
    # (#126). Mutant ids hash each file's path relative to the run directory,
    # but the config is found by walking up, so a run from a subdirectory loads
    # the same ignore list while its ids no longer match. A config in the home
    # directory is a personal default, not a project root, so it never warns.
    #
    # @param file_path [String] the .mutineer.yml that was loaded.
    # @param project_root [String] the run directory ids are relative to.
    # @return [void]
    def self.warn_config_root_mismatch(file_path, project_root)
      config_dir = ProjectPath.root_real(File.dirname(file_path))
      return if config_dir == ProjectPath.root_real(project_root)
      return if config_dir == ProjectPath.root_real(Dir.home)

      warn "[mutineer] loaded #{file_path}, but mutant ids are relative to the run directory " \
           "#{project_root}, not to #{config_dir}. Ignore ids and baselines written from " \
           "#{config_dir} will not match this run. Run mutineer from #{config_dir}."
    end

    # Warns once per old-format `ignore:` entry (#126), naming each new id it
    # matched with that mutant's file and subject. mutineer cannot tell a full
    # run from a narrowed one, so the text always says the list covers only this
    # run's mutants. An entry that matched more than one distinct mutant (in
    # other files, or same-named methods in one file) over-matched: the old id
    # could not tell them apart, so replacing it with every new id would keep
    # suppressing the mutants it hid by accident.
    #
    # @param matches [Hash{String => Array<Hash{Symbol => String}>}] old-format
    #   entry => one `{id:, file:, subject:}` hash per matched mutant.
    # @return [void]
    def self.warn_legacy_ignore_matches(matches)
      matches.each do |old, hits|
        listed = hits.map { |h| "#{h[:id]} (#{h[:file]}, #{h[:subject]})" }.join(", ")
        advice = if hits.map { |h| h[:id] }.uniq.size > 1
                   "#{old} over-matched: the old format could not tell these mutants apart. " \
                     "Replace #{old} and keep only the ids for the mutant you meant to ignore, not all of them."
                 else
                   "Replace #{old} with the new ids in your ignore list."
                 end
        warn "[mutineer] ignore entry #{old} uses the old id format, which did not include the " \
             "file path. It matched these new ids: #{listed}. This list covers only mutants in " \
             "this run's sources and operators; a run over every source gives the complete " \
             "replacement. #{advice}"
      end
    end

    # Warns once that the --baseline file stores old-format ids (#126), so the
    # diff fell back to matching on them. Called only when a survivor matched
    # through an old id alone.
    #
    # @return [void]
    def self.warn_legacy_baseline
      warn "[mutineer] the baseline uses the old id format, which did not include the file " \
           "path, so survivors were matched on their old ids and files. Regenerate the baseline " \
           "(run with --format json and save the output), but only after every gate that reads " \
           "it runs this mutineer version or later."
    end

    # Runs dry-run mode. Reuses Runner.collect_jobs (+ filter_since) so the
    # candidate list cannot drift from a real run's job selection.
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.dry_run(config)
      operator_classes = MutatorRegistry.resolve(config.operators || MutatorRegistry::DEFAULT_NAMES)
      jobs, ignored_results, source_map, extras = Runner.collect_jobs(config, operator_classes)
      warn_legacy_ignore_matches(extras[:legacy_ignore_matches])
      # Narrow jobs and ignored the same way so the summary matches the printed list.
      if config.since
        jobs = Runner.filter_since(jobs, source_map, config)
        ignored_jobs = ignored_results.map { |r| [r.subject, r.mutation, r.id] }
        ignored = Runner.filter_since(ignored_jobs, source_map, config).size
      else
        ignored = ignored_results.size
      end

      per_operator = Hash.new(0)
      skipped = 0
      jobs.each do |subject, mutation, _id|
        source = source_map[subject.file]
        unless mutation.valid?(source)
          skipped += 1
          next
        end

        line = source.byteslice(0, mutation.start_offset).count("\n") + 1
        per_operator[mutation.operator] += 1
        original = source.byteslice(mutation.start_offset...mutation.end_offset)
        puts "[#{mutation.operator}] #{subject.qualified_name}  " \
             "#{subject.file}:#{line}  `#{original}` -> `#{mutation.replacement}`"
      end

      total = per_operator.values.sum
      breakdown = per_operator.map { |op, n| "#{op}: #{n}" }.join(", ")
      summary = breakdown.empty? ? "" : "#{breakdown} — "
      puts "#{summary}#{total} mutations (dry run, not executed); " \
           "#{skipped} skipped (invalid); #{ignored} ignored (suppressed)"
      exit 0
    end
  end
end
