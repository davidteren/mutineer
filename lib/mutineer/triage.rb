# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"

module Mutineer
  # Prints `.mutineer.yml` `ignore:` entries for survivors in a JSON report.
  # The command writes to stdout and does not edit files. The user pastes the
  # lines under `ignore:`.
  module Triage
    # Usage line for a bad invocation.
    USAGE = "Usage: mutineer triage REPORT.json --reason TEXT (--id ID ... | --all)"

    # Reads argv, prints the entries, and returns the process exit code.
    # 0 is success. 2 is a usage error.
    #
    # @param argv [Array<String>] arguments after the `triage` command.
    # @param out [IO] where the entries go.
    # @param err [IO] where usage errors go.
    # @return [Integer] 0 or 2.
    def self.run(argv, out: $stdout, err: $stderr)
      reason = nil
      ids = []
      all = false
      parser = OptionParser.new do |o|
        o.banner = USAGE
        o.on("--reason TEXT") { |text| reason = text }
        o.on("--id ID") { |id| ids << id }
        o.on("--all") { all = true }
      end
      begin
        parser.parse!(argv)
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
        err.puts "mutineer: #{e.message}"
        return 2
      end

      report = argv.shift
      if argv.any?
        err.puts "mutineer: triage takes one report file"
        return 2
      end
      if report.nil? || report.empty?
        err.puts "mutineer: triage requires a JSON report file"
        return 2
      end
      text = reason.to_s.strip
      if reason.nil? || text.empty?
        err.puts "mutineer: triage requires --reason TEXT"
        return 2
      end
      if all && !ids.empty?
        err.puts "mutineer: triage takes --id or --all, not both"
        return 2
      end
      if !all && ids.empty?
        err.puts "mutineer: triage requires --id ID or --all"
        return 2
      end

      survivors = survivor_ids(report, err)
      return 2 if survivors.nil?

      chosen = all ? survivors : ids
      missing = chosen.reject { |id| survivors.include?(id) }
      unless missing.empty?
        err.puts "mutineer: triage id is not a survivor: #{missing.join(', ')}"
        return 2
      end

      entries = chosen.uniq.map { |id| { "id" => id, "reason" => text } }
      if entries.empty?
        err.puts "mutineer: triage has nothing to paste under ignore:"
        return 0
      end

      body = YAML.dump(entries).sub(/\A---\n/, "")
      out.write(body.end_with?("\n") ? body : "#{body}\n")
      0
    end

    # Survivor ids from a JSON report, in report order. Nil when the file
    # cannot be used, after a message on `err`.
    #
    # @param path [String] report path.
    # @param err [IO] usage errors.
    # @return [Array<String>, nil]
    def self.survivor_ids(path, err)
      unless File.file?(path)
        err.puts "mutineer: triage report not found: #{path}"
        return nil
      end

      doc = JSON.parse(File.read(path))
      rows = doc.is_a?(Hash) ? doc["survivors"] : nil
      unless rows.is_a?(Array)
        err.puts "mutineer: triage report has no survivors list"
        return nil
      end

      rows.filter_map { |row| row["id"] if row.is_a?(Hash) && row["id"].is_a?(String) }
    rescue JSON::ParserError => e
      err.puts "mutineer: triage report is not JSON: #{e.message}"
      nil
    rescue SystemCallError
      err.puts "mutineer: triage report cannot be read: #{path}"
      nil
    end
  end
end
