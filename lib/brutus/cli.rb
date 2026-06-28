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

module Brutus
  # Command-line entry point. `start` is the single public method called by
  # bin/brutus; it parses argv, acts, and exits with a pinned code.
  #
  # Exit codes (taxonomy consistent across M1–M5):
  #   0  success / requested output (--version, --help, score >= threshold)
  #   1  survivors below threshold, or a runtime error
  #   2  usage / flag error (unknown subcommand, invalid flag, unknown operator,
  #      out-of-range threshold)
  class CLI
    BANNER = <<~USAGE
      Usage: brutus [options] <command> [args]

      Commands:
        run [options] <source...> --test <test...>   Mutate, run, and report
        run --dry-run [options] <source...>          Print candidate mutations only

      Run options:
        --test FILE          Test file covering the sources (repeatable)
        --operators LIST     Comma-separated operator names (default: Tier 1 set)
        --threshold FLOAT    Fail (exit 1) when score < FLOAT (default: 0 = off)
        --only NAME          Restrict to one fully-qualified subject
        --jobs N             Parallel worker count (default: processor count)
        --strategy 7a|7b     Mutation application strategy (default: 7a)
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

    def self.start(argv)
      opts = {}            # symbol => value, the CLI-provided Config fields
      explicit = Set.new   # precedence keys the user typed (KTD3)
      show_operators = false

      parser = OptionParser.new do |o|
        o.banner = BANNER
        o.on("--version") do
          puts Brutus::VERSION
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
        warn "brutus: #{e.message}"
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

      file_path = Config.find_file
      file_hash = file_path ? Config.from_file(file_path) : {}
      config = Config.resolve(opts, file_hash, explicit)

      case argv.first
      when "run"
        config.sources = argv[1..]
        run(config)
      else
        warn "brutus: unknown command '#{argv.first}'"
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
        warn "brutus: run requires at least one source file"
        exit 2
      end
      validate!(config)

      config.dry_run ? dry_run(config) : execute(config)
    rescue ArgumentError => e
      # Unknown --operators value surfaces here; no backtrace reaches the user.
      warn "brutus: #{e.message}"
      exit 2
    rescue Brutus::ParseError => e
      warn "brutus: error reading: #{e.message}"
      exit 1
    end

    # New-flag validation (R24–R26, R7a is handled in Config.from_file). All emit
    # a plain-language message and exit 1; the legacy threshold-range check keeps
    # its exit-2 usage code.
    def self.validate!(config)
      unless (0.0..100.0).cover?(config.threshold)
        warn "brutus: --threshold must be between 0 and 100"
        exit 2
      end

      jobs = Integer(config.jobs.to_s, exception: false)
      if jobs.nil? || jobs < 1
        warn "brutus: --jobs requires a positive integer (got: #{config.jobs})"
        exit 1
      end
      config.jobs = jobs

      unless %w[human json].include?(config.format)
        warn %(brutus: unknown format "#{config.format}". Expected: human, json)
        exit 1
      end

      unless %w[7a 7b].include?(config.strategy)
        warn %(brutus: unknown strategy "#{config.strategy}". Expected: 7a, 7b)
        exit 1
      end

      preflight_output!(config.output) if config.output
    end

    def self.preflight_output!(path)
      dir = File.dirname(File.expand_path(path))
      return if File.directory?(dir) && File.writable?(dir)

      reason = File.directory?(dir) ? "directory is not writable" : "no such directory"
      warn "brutus: cannot write to #{path}: #{reason}"
      exit 1
    end

    def self.execute(config)
      if config.tests.empty?
        warn "brutus: run requires at least one --test file (or use --dry-run)"
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
            original = source[mutation.start_offset...mutation.end_offset]
            line = source[0...mutation.start_offset].count("\n") + 1
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
