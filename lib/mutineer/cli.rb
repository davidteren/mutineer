# frozen_string_literal: true

require "optparse"
require "set"
require "open3"
require_relative "version"
require_relative "config"
require_relative "parser"
require_relative "project"
require_relative "pairing"
require_relative "changed_lines"
require_relative "runner"
require_relative "reporter"
require_relative "baseline"
require_relative "mutator_registry"

module Mutineer
  # Command-line entry point. `start` is the single public method called by
  # bin/mutineer; it parses argv, acts, and exits with a pinned code.
  #
  # Exit codes (taxonomy consistent across M1–M5):
  #   0  success / requested output (--version, --help, score >= threshold)
  #   1  survivors below threshold, or a runtime error
  #   2  usage / flag error (unknown subcommand, invalid flag, unknown operator,
  #      out-of-range threshold)
  class CLI
    # Command-line usage banner.
    BANNER = <<~USAGE
      Usage: mutineer [options] <command> [args]

      Commands:
        run [options] <source...> --test <test...>   Mutate, run, and report
        run --dry-run [options] <source...>          Print candidate mutations only

      Run options:
        --test FILE          Test file covering the sources (repeatable)
        --operators LIST     Comma-separated operator names (default: Tier 1 set)
        --threshold FLOAT    Fail (exit 1) when score < FLOAT (default: 0 = off)
        --baseline FILE      Fail (exit 1) on NEW survivors / score drop vs a prior
                             --format json run (CI delta gate)
        --baseline-epsilon FLOAT  Score-drop tolerance for --baseline (default: 0)
        --only NAME          Restrict to one fully-qualified subject
        --since REF          Only mutate lines changed since git REF (e.g. origin/main)
        --jobs N             Parallel worker count (default: processor count)
        --strategy NAME      reload (whole-file) or redefine (surgical); default: reload
        --framework NAME     minitest or rspec (default: auto-detect from --test names)
        --boot FILE          Require FILE once in the parent to boot the app env, then
                             fork per mutant (Rails apps; requires --test)
        --rails              Sugar for --boot config/environment --strategy redefine
        --test-command CMD   Run the target suite in the app's own runtime as a
                             subprocess (for apps on Ruby < 3.4). CMD must contain
                             %{files} (expands to the --test paths). Env is inherited,
                             e.g. RAILS_ENV=test mutineer run ... --test-command "..."
        --format human|json|html  Report format (default: human)
        --output FILE        Write the report to FILE instead of stdout
        --dry-run            List mutations without executing
        --fail-fast          Stop at the first surviving mutant
        --verbose            Surface the real error when a fork capture fails (alias: --debug)

      Options:
        --list-operators  List available operators (default vs optional) and exit
        --version         Print version and exit
        --help            Print this help and exit
    USAGE

    # Field symbols whose config-file value is suppressed when the flag is typed.
    PRECEDENCE_FLAGS = %i[operators jobs threshold only].freeze

    # Deprecated internal strategy names, mapped to their canonical equivalents.
    STRATEGY_ALIASES = { "7a" => "reload", "7b" => "redefine" }.freeze

    # Parses arguments, executes the command, and exits.
    #
    # @param argv [Array<String>] raw command-line arguments.
    # @return [void]
    def self.start(argv)
      opts = {}            # symbol => value, the CLI-provided Config fields
      explicit = Set.new   # precedence keys the user typed (KTD3)
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
        o.on("--only NAME") { |v| opts[:only] = v; explicit << :only }
        o.on("--since REF") { |v| opts[:since] = v; explicit << :since }
        o.on("--test FILE") { |v| (opts[:tests] ||= []) << v }
        o.on("--operators LIST") { |v| opts[:operators] = v.split(",").map(&:strip); explicit << :operators }
        o.on("--threshold FLOAT") { |v| opts[:threshold] = v.to_f; explicit << :threshold }
        o.on("--jobs N") { |v| opts[:jobs] = v; explicit << :jobs }
        o.on("--strategy STRAT") { |v| opts[:strategy] = v; explicit << :strategy }
        o.on("--framework NAME") { |v| opts[:framework] = v; explicit << :framework }
        o.on("--boot FILE") { |v| opts[:boot] = v; explicit << :boot }
        o.on("--rails") { opts[:rails] = true }
        o.on("--verbose") { opts[:verbose] = true }
        o.on("--debug") { opts[:verbose] = true } # alias of --verbose
        o.on("--format FORMAT") { |v| opts[:format] = v }
        o.on("--output FILE") { |v| opts[:output] = v }
        # #13: --baseline is also a .mutineer.yml key, so mark it explicit when
        # typed (CLI wins over the file). --baseline-epsilon is CLI-only.
        o.on("--baseline FILE") { |v| opts[:baseline] = v; explicit << :baseline }
        o.on("--baseline-epsilon FLOAT") { |v| opts[:baseline_epsilon] = v.to_f }
        # #27: run the target suite as a subprocess in the app's OWN runtime so
        # mutineer (Ruby >= 3.4) can mutation-test apps pinned to an older Ruby.
        o.on("--test-command CMD") { |v| opts[:test_command] = v; explicit << :test_command }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
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
        file_hash = file_path ? Config.from_file(file_path) : {}
        config = Config.resolve(opts, file_hash, explicit)
      rescue Mutineer::ConfigError => e
        # R8: the lib layer raises instead of killing the host; the CLI maps a
        # config (usage) error to exit 2.
        warn "mutineer: #{e.message}"
        exit 2
      end

      case argv.first
      when "run"
        # #11: a directory source expands to its **/*.rb files; literal files pass
        # through. Test inference (when --test is omitted) happens in validate!.
        config.sources = Pairing.expand_sources(argv[1..], project_root: config.project_root)
        run(config, explicit)
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
    # @param explicit [Set<Symbol>] explicit CLI fields.
    # @return [void]
    def self.run(config, explicit = Set.new)
      if config.sources.empty?
        warn "mutineer: run requires at least one source file"
        exit 2
      end
      validate!(config, explicit)

      config.dry_run ? dry_run(config) : execute(config)
    rescue ArgumentError => e
      # Unknown --operators value surfaces here; no backtrace reaches the user.
      warn "mutineer: #{e.message}"
      exit 2
    rescue SystemCallError => e
      # R5: a missing/unreadable path reaches here as Errno::ENOENT etc. — a plain
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
    end

    # Flag validation: every flag/usage failure exits 2 (C7), consistent with the
    # taxonomy above — CI can tell "mistyped flag" from "tests too weak."
    # Validates the run configuration.
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @param explicit [Set<Symbol>] explicit CLI fields.
    # @return [void]
    def self.validate!(config, explicit = Set.new)
      unless (0.0..100.0).cover?(config.threshold)
        warn "mutineer: --threshold must be between 0 and 100"
        exit 2
      end

      jobs = Integer(config.jobs.to_s, exception: false)
      if jobs.nil? || jobs < 1
        warn "mutineer: --jobs requires a positive integer (got: #{config.jobs})"
        exit 2
      end
      config.jobs = jobs

      unless %w[human json html].include?(config.format)
        warn %(mutineer: unknown format "#{config.format}". Expected: human, json, html)
        exit 2
      end

      # Canonical strategies are reload|redefine; 7a/7b are accepted as deprecated
      # aliases. Normalize to canonical so the rest of the pipeline sees one name.
      config.strategy = STRATEGY_ALIASES.fetch(config.strategy, config.strategy)
      unless %w[reload redefine].include?(config.strategy)
        warn %(mutineer: unknown strategy "#{config.strategy}". Expected: reload, redefine)
        exit 2
      end

      unless %w[minitest rspec].include?(config.framework)
        warn %(mutineer: unknown framework "#{config.framework}". Expected: minitest, rspec)
        exit 2
      end

      validate_test_command!(config) if config.test_command

      validate_since!(config) if config.since
      preflight_output!(config.output) if config.output
      preflight_baseline!(config.baseline) if config.baseline

      # #11: when --test is omitted, infer each source's test by convention so the
      # boot-once/fork-per-test core (which pairs empirically by coverage) gets a
      # populated config.tests. Runs after every flag/usage check above so a
      # mistyped flag still reports the flag; skipped under --dry-run (no tests
      # needed). validate_paths! then sees the inferred (real) tests.
      autopair!(config, explicit) unless config.dry_run

      # Boot mode does no coverage selection — every mutant runs the given tests —
      # so at least one --test file is mandatory (there is nothing to select from).
      if config.boot && config.tests.empty?
        warn "mutineer: --boot/--rails requires at least one --test file"
        exit 2
      end

      validate_paths!(config)
    end

    # #27: --test-command runs the target suite in the app's own runtime. Validate
    # its shape up front (usage errors → exit 2) and force serial execution: each
    # subprocess boots the app and opens its own fixture transaction against the
    # same DB, so --jobs > 1 would corrupt results (the #12 fixture-contention
    # hazard). Unlike --rails, this path has NO per-worker DB isolation to opt into,
    # so an explicit --jobs N is forced to 1 rather than honored (KTD-5).
    # Validates the --test-command configuration.
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

    # --since needs a real git repo and a resolvable ref; either failure is a
    # usage error (exit 2) so CI sees "bad invocation," not "tests too weak."
    # Validates the --since ref.
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

    # R5: validate path existence up front so a typo is a clean usage error (exit
    # 2), not an Errno::ENOENT backtrace from deep in the run. Flag checks run
    # first so a bad flag still reports the flag, not the missing file.
    # Validates source and test paths.
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

    # #11: auto-pair sources to tests by path convention when no --test was given
    # (explicit --test wins — R5). Each source with an inferred test on disk joins
    # the run; a source with none is dropped with a one-line stderr warning (R3)
    # and the run continues with the rest. If every source is dropped: in boot mode
    # the dedicated --boot/--rails-requires-test check reports it; otherwise exit 2
    # with a usage message. The framework is re-detected from the inferred set
    # unless it was set explicitly (a spec-only project loads/reports as rspec).
    # Auto-pairs sources and tests when --test is absent.
    #
    # @api private
    # @param config [Mutineer::Config] run configuration.
    # @param explicit [Set<Symbol>] explicit CLI fields.
    # @return [void]
    def self.autopair!(config, explicit)
      return unless config.tests.empty?

      paired = config.sources.filter_map do |s|
        t = Pairing.infer_test(s, project_root: config.project_root, prefer: config.framework)
        [s, t] if t
      end
      (config.sources - paired.map(&:first)).each do |s|
        warn "[mutineer] no test found by convention for #{s}; skipping"
      end
      config.sources = paired.map(&:first)
      config.tests   = paired.map(&:last).uniq
      config.framework = Config.detect_framework(config.tests) unless explicit.include?(:framework)

      return unless config.sources.empty?
      return if config.boot # let the --boot/--rails-requires-test check report it

      warn "mutineer: no test files found by convention; pass --test or add tests"
      exit 2
    end

    # #13: a missing/unreadable/unparseable baseline is a usage error (exit 2),
    # mirroring --output/--since preflight, so CI sees "bad invocation," not a
    # backtrace mid-run. Validating up front = attempting the load (it raises
    # ConfigError/SystemCallError; the actual diff reloads in execute).
    # Preflights a baseline file.
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

      aggregate, source_map = Runner.execute(config)
      reporter = Reporter.new(aggregate, source_map)

      # #13: diff the current run against the baseline (preflighted above) by the
      # stable survivor id. The delta is rendered inline (human section / additive
      # json block) and gates exit independently of --threshold.
      delta = (Baseline.load(config.baseline).diff(aggregate, epsilon: config.baseline_epsilon) if config.baseline)

      reporter.report(out: $stdout, err: $stderr, threshold: config.threshold,
                      format: config.format, output: config.output, baseline: delta)

      # #14: nudge toward the opt-in tier-2 operators (human report only — never
      # pollute JSON output).
      if !%w[json html].include?(config.format) && (hint = tier2_hint(config.operators))
        puts hint
      end

      # #13/KTD-4: --baseline and --threshold are independent gates OR'd together.
      # `max` of two 0/1 codes is the OR; usage (2) is handled earlier and wins.
      baseline_exit = delta&.regressed ? 1 : 0
      exit [reporter.exit_code(threshold: config.threshold), baseline_exit].max
    end

    # The tier-2 operators not in the active set, as a one-line hint (or nil when
    # they're all already enabled). `active` nil means the default (Tier-1) set.
    # Builds a Tier-2 operator hint.
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

    # Runs dry-run mode.
    #
    # @param config [Mutineer::Config] run configuration.
    # @return [void]
    def self.dry_run(config)
      operator_classes = MutatorRegistry.resolve(config.operators || MutatorRegistry::DEFAULT_NAMES)
      sources = {}
      per_operator = Hash.new(0)
      skipped = 0
      ignored = 0
      ignore_set = config.ignore.to_set

      # --since narrows the preview to changed lines too, so `--dry-run --since`
      # shows exactly what a real `--since` run would mutate.
      changed = if config.since
                  ChangedLines.for(ref: config.since, files: config.sources,
                                   project_root: config.project_root)
                end

      Project.discover(config.sources, only: config.only).each do |subject|
        source = (sources[subject.file] ||= Parser.parse_file(subject.file).source.source)
        # #22: honor suppression so the preview matches what a real run mutates.
        # Mirror execute's per-subject shape (ids need the full mutation list).
        disabled = Runner.suppress_map(source)
        mutations = operator_classes.flat_map { |klass| klass.new.mutations_for(subject, source) }
        ids = MutantId.for_subject(subject, source, mutations)
        mutations.each_with_index do |mutation, i|
          unless mutation.valid?(source)
            skipped += 1
            next
          end
          line = source.byteslice(0, mutation.start_offset).count("\n") + 1
          next if changed && !changed[File.expand_path(subject.file, config.project_root)]&.include?(line)

          if Runner.suppressed?(mutation.operator, line, ids[i], disabled, ignore_set)
            ignored += 1
            next
          end

          per_operator[mutation.operator] += 1
          original = source.byteslice(mutation.start_offset...mutation.end_offset)
          puts "[#{mutation.operator}] #{subject.qualified_name}  " \
               "#{subject.file}:#{line}  `#{original}` -> `#{mutation.replacement}`"
        end
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
