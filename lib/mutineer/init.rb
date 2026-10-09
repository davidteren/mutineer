# frozen_string_literal: true

require "optparse"
require_relative "config"
require_relative "mutator_registry"

module Mutineer
  # Writes a starter `.mutineer.yml` and prints the first run command.
  # It does not replace an existing file unless `--force` is set.
  module Init
    # Usage line for a bad invocation.
    USAGE = "Usage: mutineer init [--rails] [--force]"

    # Writes the config and prints the first command.
    # 0 is success. 2 is a usage error or a refused overwrite.
    #
    # @param argv [Array<String>] arguments after `init`.
    # @param out [IO] where the command goes.
    # @param err [IO] where errors go.
    # @param dir [String] directory that receives `.mutineer.yml`.
    # @return [Integer] 0 or 2.
    def self.run(argv, out: $stdout, err: $stderr, dir: Dir.pwd)
      rails = false
      force = false
      help = false
      parser = OptionParser.new do |o|
        o.banner = USAGE
        o.on("--rails") { rails = true }
        o.on("--force") { force = true }
        o.on("--help") { help = true }
      end
      begin
        parser.parse!(argv)
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
        err.puts "mutineer: #{e.message}"
        return 2
      end
      if help
        out.puts USAGE
        return 0
      end
      unless argv.empty?
        err.puts "mutineer: init takes no source paths"
        return 2
      end

      path = File.join(dir, CONFIG_FILE)
      if File.directory?(path)
        err.puts "mutineer: #{CONFIG_FILE} is a directory"
        return 2
      end
      if File.exist?(path) && !force
        err.puts "mutineer: #{CONFIG_FILE} already exists. Pass --force to replace it."
        return 2
      end

      File.write(path, template(rails: rails))
      out.puts command_for(dir, rails: rails)
      0
    end

    # Starter config. `since` stays commented so the first run is a full scan.
    # `--rails` also sets `rails: true` and leaves `daemon` commented.
    #
    # @param rails [Boolean] when true, set `rails: true`.
    # @return [String] YAML text.
    def self.template(rails:)
      operators = MutatorRegistry::DEFAULT_NAMES.map { |name| "  - #{name}" }.join("\n")
      head = <<~YAML
        # Mutineer config. Command-line flags override this file.
        # These operators are the default set.
        operators:
      YAML
      tail = <<~YAML
        # since: origin/main
        # Leave this commented so the first run is a full scan.
      YAML
      body = "#{head}#{operators}\n\n#{tail}"
      return body unless rails

      extra = <<~YAML
        rails: true

        # daemon: true
        # Leave this commented until the support matrix says the daemon fits.
        # The matrix is on https://davidteren.github.io/mutineer/rails.html#daemon
      YAML
      "#{body.rstrip}\n\n#{extra}"
    end

    # The first run command. Plain init names `lib`.
    # `--rails` names `app/models` and `lib`, plus `app/services` when that folder exists.
    #
    # @param dir [String] project directory.
    # @param rails [Boolean] when true, print the Rails source folders.
    # @return [String]
    def self.command_for(dir, rails:)
      return "mutineer run lib" unless rails

      folders = ["app/models"]
      folders << "app/services" if File.directory?(File.join(dir, "app", "services"))
      folders << "lib"
      "mutineer run #{folders.join(" ")}"
    end
  end
end
