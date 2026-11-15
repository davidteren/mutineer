# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"

module Mutineer
  # Prints `.mutineer.yml` `ignore:` entries for survivors in a JSON report,
  # and for each copy dropped as a repeat of one of those survivors (#374).
  # An entry still ignores only its own id. The command writes to stdout and
  # does not edit files. The user pastes the lines under `ignore:`.
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
      rescue OptionParser::ParseError => e
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

      groups = survivor_groups(report, err)
      return 2 if groups.nil?

      by_id = groups.to_h
      copy_owner = {}
      groups.each { |id, copies| copies.each { |copy| copy_owner[copy] ||= id } }

      chosen = all ? groups.map(&:first) : ids
      missing = chosen.reject { |id| by_id.key?(id) || copy_owner.key?(id) }
      unless missing.empty?
        err.puts "mutineer: triage id is not a survivor or one of its copies: #{missing.join(', ')}"
        return 2
      end

      seen_owners = {}
      seen_entry_ids = {}
      entries = []
      chosen.uniq.each do |id|
        owner = by_id.key?(id) ? id : copy_owner[id]
        next if seen_owners[owner]

        seen_owners[owner] = true
        ([owner] + by_id[owner]).each do |entry_id|
          next if seen_entry_ids[entry_id]

          seen_entry_ids[entry_id] = true
          entries << { "id" => entry_id, "reason" => text }
        end
      end
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
      groups = survivor_groups(path, err)
      groups&.map(&:first)
    end

    # Each survivor id and the dropped-copy ids listed on it, in report order.
    # A `copies` value that is not a list counts as none. Nil when the file
    # cannot be used, after a message on `err`.
    #
    # @param path [String] report path.
    # @param err [IO] usage errors.
    # @return [Array<Array(String, Array<String>)>, nil]
    def self.survivor_groups(path, err)
      unless File.file?(path)
        err.puts "mutineer: triage report not found: #{path}"
        return nil
      end

      doc = JSON.parse(File.read(path, encoding: "UTF-8"))
      rows = doc.is_a?(Hash) ? doc["survivors"] : nil
      unless rows.is_a?(Array)
        err.puts "mutineer: triage report has no survivors list"
        return nil
      end

      rows.filter_map { |row| group_for(row) }
    rescue JSON::ParserError => e
      err.puts "mutineer: triage report is not JSON: #{e.message}"
      nil
    rescue SystemCallError
      err.puts "mutineer: triage report cannot be read: #{path}"
      nil
    end

    # One survivor and its copy ids, or nil when the row has no id.
    #
    # @api private
    # @param row [Object] one `survivors[]` element.
    # @return [Array(String, Array<String>), nil]
    def self.group_for(row)
      return unless row.is_a?(Hash) && row["id"].is_a?(String) && !row["id"].empty?

      raw = row["copies"]
      copies = raw.is_a?(Array) ? raw : []
      copies = copies.select { |id| id.is_a?(String) && !id.empty? && id != row["id"] }.uniq
      [row["id"], copies]
    end
  end
end
