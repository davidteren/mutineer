# frozen_string_literal: true

require "optparse"
require "set"
require_relative "version"
require_relative "config"
require_relative "parser"
require_relative "project"
require_relative "runner"
require_relative "reporter"
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
    BANNER = <<~USAGE
      Usage: mutineer [options] <command> [args]

      Commands:
        run [options] <source...> --test <test...>   Mutate, run, and report
        run --dry-run [options] <source...>          Print candidate mutations only

      Run options:
        --test FILE          Test file covering the sources (repeatable)
        --operators LIST     Comma-separated operator names (default: Tier 1 set)
        --threshold FLOAT    Fail (exit 1) when score < FLOAT (default: 0 = off)
        --only NAME          Restrict to one fully-qualified subject
        --jobs N             Parallel worker count (default: processor count)
        --strategy NAME      reload (whole-file) or redefine (surgical); default: reload
        --format human|json  Report format (default: human)
        --output FILE        Write the report to FILE instead of stdout
        --dry-run            List mutations without executing

      Options:
        --list-operators  List available operators (default vs optional) and exit
        --version         Print version and exit
        --help            Print this help and exit
    USAGE

    # Field symbols whose config-file value is suppressed when the flag is typed.
    PRECEDENCE_FLAGS = %i[operators jobs threshold only].freeze

    # Deprecated internal strategy names, mapped to their canonical equivalents.
    STRATEGY_ALIASES = { "7a" => "reload", "7b" => "redefine" }.freeze

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
        o.on("--only NAME") { |v| opts[:only] = v; explicit << :only }
        o.on("--test FILE") { |v| (opts[:tests] ||= []) << v }
        o.on("--operators LIST") { |v| opts[:operators] = v.split(",").map(&:strip); explicit << :operators }
        o.on("--threshold FLOAT") { |v| opts[:threshold] = v.to_f; explicit << :threshold }
        o.on("--jobs N") { |v| opts[:jobs] = v; explicit << :jobs }
        o.on("--strategy STRAT") { |v| opts[:strategy] = v }
        o.on("--format FORMAT") { |v| opts[:format] = v }
        o.on("--output FILE") { |v| opts[:output] = v }
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
        config.sources = argv[1..]
        run(config)
      else
        warn "mutineer: unknown command '#{argv.first}'"
        exit 2
      end
    end

    def self.list_operators
      MutatorRegistry::ALL.each_key do |name|
        state = MutatorRegistry.default?(name) ? "default" : "disabled"
        puts format("%-20s tier %d  %-9s %s",
                    name, MutatorRegistry.tier(name), state, MutatorRegistry::DESCRIPTIONS[name])
      end
    end

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
    def self.validate!(config)
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

      unless %w[human json].include?(config.format)
        warn %(mutineer: unknown format "#{config.format}". Expected: human, json)
        exit 2
      end

      # Canonical strategies are reload|redefine; 7a/7b are accepted as deprecated
      # aliases. Normalize to canonical so the rest of the pipeline sees one name.
      config.strategy = STRATEGY_ALIASES.fetch(config.strategy, config.strategy)
      unless %w[reload redefine].include?(config.strategy)
        warn %(mutineer: unknown strategy "#{config.strategy}". Expected: reload, redefine)
        exit 2
      end

      preflight_output!(config.output) if config.output
      validate_paths!(config)
    end

    # R5: validate path existence up front so a typo is a clean usage error (exit
    # 2), not an Errno::ENOENT backtrace from deep in the run. Flag checks run
    # first so a bad flag still reports the flag, not the missing file.
    def self.validate_paths!(config)
      missing = (config.sources + config.tests)
                .reject { |p| File.exist?(File.expand_path(p, config.project_root)) }
      return if missing.empty?

      warn "mutineer: no such file: #{missing.join(', ')}"
      exit 2
    end

    def self.preflight_output!(path)
      dir = File.dirname(File.expand_path(path))
      return if File.directory?(dir) && File.writable?(dir)

      reason = File.directory?(dir) ? "directory is not writable" : "no such directory"
      warn "mutineer: cannot write to #{path}: #{reason}"
      exit 2
    end

    def self.execute(config)
      if config.tests.empty?
        warn "mutineer: run requires at least one --test file (or use --dry-run)"
        exit 2
      end

      aggregate, source_map = Runner.execute(config)
      reporter = Reporter.new(aggregate, source_map)
      reporter.report(out: $stdout, err: $stderr, threshold: config.threshold,
                      format: config.format, output: config.output)
      exit reporter.exit_code(threshold: config.threshold)
    end

    def self.dry_run(config)
      operator_classes = MutatorRegistry.resolve(config.operators || MutatorRegistry::DEFAULT_NAMES)
      sources = {}
      per_operator = Hash.new(0)
      skipped = 0

      Project.discover(config.sources, only: config.only).each do |subject|
        source = (sources[subject.file] ||= Parser.parse_file(subject.file).source.source)
        operator_classes.each do |klass|
          klass.new.mutations_for(subject, source).each do |mutation|
            unless mutation.valid?(source)
              skipped += 1
              next
            end
            per_operator[mutation.operator] += 1
            original = source.byteslice(mutation.start_offset...mutation.end_offset)
            line = source.byteslice(0, mutation.start_offset).count("\n") + 1
            puts "[#{mutation.operator}] #{subject.qualified_name}  " \
                 "#{subject.file}:#{line}  `#{original}` -> `#{mutation.replacement}`"
          end
        end
      end

      total = per_operator.values.sum
      breakdown = per_operator.map { |op, n| "#{op}: #{n}" }.join(", ")
      summary = breakdown.empty? ? "" : "#{breakdown} — "
      puts "#{summary}#{total} mutations (dry run, not executed); #{skipped} skipped (invalid)"
      exit 0
    end
  end
end
