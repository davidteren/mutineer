# frozen_string_literal: true

require "optparse"
require_relative "version"

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
        run <path>    Run mutation testing (not yet implemented)

      Options:
        --version     Print version and exit
        --help        Print this help and exit
    USAGE

    def self.start(argv)
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
        warn "run: not yet implemented"
        exit 1
      else
        warn "brutus: unknown command '#{argv.first}'"
        exit 1
      end
    end
  end
end
