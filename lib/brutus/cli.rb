# frozen_string_literal: true

require "optparse"
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
        --operators LIST     Comma-separated operator names (default: all)
        --threshold FLOAT    Fail (exit 1) when score < FLOAT (default: 0 = off)
        --only NAME          Restrict to one fully-qualified subject
        --dry-run            List mutations without executing

      Options:
        --version     Print version and exit
        --help        Print this help and exit
    USAGE

    def self.start(argv)
      config = Config.new
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
        o.on("--dry-run") { config.dry_run = true }
        o.on("--only NAME") { |v| config.only = v }
        o.on("--test FILE") { |v| (config.tests ||= []) << v }
        o.on("--operators LIST") { |v| config.operators = v.split(",").map(&:strip) }
        o.on("--threshold FLOAT") { |v| config.threshold = v.to_f }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
        warn "brutus: #{e.message}"
        exit 2
      end

      if argv.empty?
        puts BANNER
        exit 0
      end

      case argv.first
      when "run"
        config.sources = argv[1..]
        run(config)
      else
        warn "brutus: unknown command '#{argv.first}'"
        exit 2
      end
    end

    def self.run(config)
      if config.sources.empty?
        warn "brutus: run requires at least one source file"
        exit 2
      end
      unless (0.0..100.0).cover?(config.threshold)
        warn "brutus: --threshold must be between 0 and 100"
        exit 2
      end

      config.dry_run ? dry_run(config) : execute(config)
    rescue ArgumentError => e
      # Unknown --operators value surfaces here; no backtrace reaches the user.
      warn "brutus: #{e.message}"
      exit 2
    rescue Brutus::ParseError => e
      warn "brutus: error reading: #{e.message}"
      exit 1
    end

    def self.execute(config)
      if config.tests.empty?
        warn "brutus: run requires at least one --test file (or use --dry-run)"
        exit 2
      end

      aggregate, source_map = Runner.execute(config)
      reporter = Reporter.new(aggregate, source_map)
      reporter.report(out: $stdout, err: $stderr, threshold: config.threshold)
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
