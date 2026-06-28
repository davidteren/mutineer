# frozen_string_literal: true

require "optparse"
require_relative "version"
require_relative "parser"
require_relative "project"
require_relative "mutators/arithmetic"

module Brutus
  # Command-line entry point. `start` is the single public method called by
  # bin/brutus; it parses argv, acts, and exits with a pinned code.
  #
  # Exit codes (fixed from M0, relied on by CI scripts in M1+):
  #   0  success / requested output (--version, --help, no-args usage)
  #   1  runtime error, unimplemented stub, unknown subcommand, invalid flag
  #   2  reserved (not used in M0)
  class CLI
    BANNER = <<~USAGE
      Usage: brutus [options] <command> [args]

      Commands:
        run --dry-run [--only NAME] <path...>   Print candidate mutations (no execution)

      Options:
        --version     Print version and exit
        --help        Print this help and exit
    USAGE

    def self.start(argv)
      opts = {}
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
        o.on("--dry-run") { opts[:dry_run] = true }
        o.on("--only NAME") { |v| opts[:only] = v }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::InvalidOption => e
        # optparse would exit 2; re-exit 1 so flag- and subcommand-errors match.
        warn "brutus: #{e.message}"
        exit 1
      end

      if argv.empty?
        puts BANNER
        exit 0
      end

      case argv.first
      when "run"
        run(argv[1..], opts)
      else
        warn "brutus: unknown command '#{argv.first}'"
        exit 1
      end
    end

    def self.run(files, opts)
      unless opts[:dry_run]
        warn "run requires --dry-run; execution not yet implemented"
        exit 1
      end

      if files.empty?
        warn "brutus: run --dry-run requires at least one file"
        exit 1
      end

      sources = {}
      subjects =
        begin
          Brutus::Project.discover(files, only: opts[:only]).each do |s|
            sources[s.file] ||= Brutus::Parser.parse_file(s.file).source.source
          end
        rescue Brutus::ParseError => e
          warn "brutus: error reading: #{e.message}"
          exit 1
        end

      mutator = Brutus::Mutators::Arithmetic.new
      found = 0
      skipped = 0

      subjects.each do |subject|
        source = sources[subject.file]
        mutator.mutations_for(subject, source).each do |mutation|
          unless mutation.valid?(source)
            skipped += 1
            next
          end
          found += 1
          original = source[mutation.start_offset...mutation.end_offset]
          line = source[0...mutation.start_offset].count("\n") + 1
          puts "[#{mutation.operator}] #{subject.qualified_name}  " \
               "#{subject.file}:#{line}  `#{original}` -> `#{mutation.replacement}`"
        end
      end

      puts "Dry-run: #{found} mutations found, #{skipped} skipped (invalid)"
      exit 0
    end
  end
end
