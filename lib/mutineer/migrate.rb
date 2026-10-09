# frozen_string_literal: true

require "set"
require_relative "job_plan"
require_relative "mutator_registry"

module Mutineer
  # Rewrites old-format mutant ids in a `.mutineer.yml` `ignore:` list to the
  # current id format. The map is the inverse of the `id_map` from
  # {JobPlan.collect_jobs}: each old id goes to every new id that still hashes
  # to it, in collection order. The map covers only the configured operators
  # and the sources on the command line. Ids are static hashes, so this runs
  # no tests.
  #
  # The file is edited as text. A YAML load and dump would drop comments and
  # reorder keys. Only a bare id string inside `ignore:` is replaced. A
  # `{ id:, reason: }` entry is left as written. A baseline file is never read.
  module Migrate
    # One old id and the new ids that replace it, in collection order.
    Replacement = Data.define(:old_id, :new_ids)

    # The outcome of rewriting one file in memory. `text` is what to write.
    # It equals the input when nothing changed. `unmapped` holds bare ids that
    # matched no mutant, in file order, each once.
    Outcome = Data.define(:replacements, :unmapped, :text)

    # Builds the id maps for `config`'s sources and operators.
    #
    # @param config [Mutineer::Config] run configuration, with sources set.
    # @return [Array(Set<String>, Hash{String => Array<String>})]
    #   the current new ids, and each old id => its new ids.
    def self.id_maps(config)
      names = config.operators || MutatorRegistry::DEFAULT_NAMES
      _jobs, _ignored, _source_map, extras = JobPlan.collect_jobs(config, MutatorRegistry.resolve(names))
      old_to_new = {}
      extras[:id_map].each do |new_id, old_id|
        list = (old_to_new[old_id] ||= [])
        list << new_id unless list.include?(new_id)
      end
      [extras[:id_map].keys.to_set, old_to_new]
    end

    # Rewrites `ignore:` ids in `text`. An id that is already a current new id
    # stays, so a second run does not change the file. An old id is replaced by
    # every new id it maps to. Any other bare id stays and is listed in
    # {Outcome#unmapped}.
    #
    # @param text [String] the `.mutineer.yml` contents.
    # @param current [Set<String>] new-format ids in this run.
    # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
    # @return [Outcome]
    def self.rewrite(text, current, old_to_new)
      replacements = []
      unmapped = []
      lines = []
      pending = text.lines
      while (line = pending.shift)
        case line_kind(line)
        when :flow
          lines << rewrite_flow(line, current, old_to_new, replacements, unmapped)
        when :scalar
          lines.concat(rewrite_scalar(line, current, old_to_new, replacements, unmapped))
        when :block
          lines << line
          while (next_line = pending.first) && inside_block?(next_line)
            lines.concat(rewrite_item(pending.shift, current, old_to_new, replacements, unmapped))
          end
        else
          lines << line
        end
      end
      Outcome.new(replacements: replacements, unmapped: unmapped, text: lines.join)
    end

    class << self
      private

      # A bare id token, optionally quoted, not part of a longer hex string.
      ID_TOKEN = /(?<![0-9a-f])(['"]?)([0-9a-f]{12})\1(?![0-9a-f])/

      # A block-list item whose value is one bare id.
      ITEM = /\A([ \t]*-[ \t]+)(['"]?)([0-9a-f]{12})\2([ \t]*(?:\#.*)?)(\r?\n)?\z/

      # `ignore:` followed by one bare id on the same line.
      SCALAR = /\A(ignore:[ \t]*)(['"]?)([0-9a-f]{12})\2([ \t]*(?:\#.*)?)(\r?\n)?\z/

      # Which `ignore:` shape this line opens, or nil when it is some other line.
      #
      # @param line [String] one line of the file, its terminator included.
      # @return [Symbol, nil] `:flow`, `:block`, `:scalar`, or nil.
      def line_kind(line)
        return :flow if line.match?(/\Aignore:[ \t]*\[/)
        return :block if line.match?(/\Aignore:[ \t]*(?:\#.*)?\r?\n?\z/)
        return :scalar if line.match?(/\Aignore:[ \t]*\S/)

        nil
      end

      # Whether `line` still belongs to a block-style `ignore:` value.
      # A later root key does not. A blank line, a comment, an indented line,
      # or a list item (indented or at column 0) does.
      #
      # @param line [String] the next line.
      # @return [Boolean]
      def inside_block?(line)
        line.match?(/\A[ \t]*(?:\#.*)?\r?\n?\z/) || line.match?(/\A[ \t]*-[ \t]/) || line.match?(/\A[ \t]+\S/)
      end

      # The ids to write for one bare id. Records a replacement or an unmapped
      # id. An id that is already current is returned unchanged and unrecorded,
      # even when it also equals some other mutant's old id.
      #
      # @param id [String] the id in the file.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes, in file order.
      # @param unmapped [Array<String>] bare ids that matched nothing.
      # @return [Array<String>] the ids to write in this position.
      def mapped_ids(id, current, old_to_new, replacements, unmapped)
        return [id] if current.include?(id)

        news = old_to_new[id]
        if news
          replacements << Replacement.new(old_id: id, new_ids: news.dup) unless news == [id]
          news.dup
        else
          unmapped << id unless unmapped.include?(id)
          [id]
        end
      end

      # Rewrites bare ids between the brackets of a one-line flow list.
      #
      # @param line [String] an `ignore: [...]` line.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] bare ids that matched nothing.
      # @return [String] the line to write.
      def rewrite_flow(line, current, old_to_new, replacements, unmapped)
        match = line.match(/\A(ignore:[ \t]*\[)(.*?)(\].*)\z/m)
        return line unless match

        inner = match[2].gsub(ID_TOKEN) do
          quote = Regexp.last_match(1)
          ids = mapped_ids(Regexp.last_match(2), current, old_to_new, replacements, unmapped)
          ids.map { |new_id| "#{quote}#{new_id}#{quote}" }.join(", ")
        end
        "#{match[1]}#{inner}#{match[3]}"
      end

      # Rewrites a one-line `ignore: <id>`. Several new ids become a block list,
      # so each id stays a bare string. The comment stays on the key line.
      #
      # @param line [String] an `ignore: <id>` line.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] bare ids that matched nothing.
      # @return [Array<String>] the lines to write.
      def rewrite_scalar(line, current, old_to_new, replacements, unmapped)
        match = SCALAR.match(line)
        return [line] unless match

        ids = mapped_ids(match[3], current, old_to_new, replacements, unmapped)
        quote = match[2]
        if ids.size == 1
          ["#{match[1]}#{quote}#{ids.first}#{quote}#{match[4]}#{match[5]}"]
        else
          ending = match[5].to_s
          ending = "\n" if ending.empty?
          ["ignore:#{match[4]}#{ending}", *render_lines("  - ", quote, ids, "", ending)]
        end
      end

      # Rewrites one block-list item, or returns the line unchanged when it is
      # not a bare id (a comment, a blank line, or a `{ id:, reason: }` entry).
      #
      # @param line [String] one line inside an `ignore:` block.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] bare ids that matched nothing.
      # @return [Array<String>] the lines to write.
      def rewrite_item(line, current, old_to_new, replacements, unmapped)
        match = ITEM.match(line)
        return [line] unless match

        ids = mapped_ids(match[3], current, old_to_new, replacements, unmapped)
        render_lines(match[1], match[2], ids, match[4], match[5].to_s)
      end

      # One list item per id. The original comment stays on the first item.
      # Only the last item keeps the original line ending, so a file that does
      # not end in a newline still does not.
      #
      # @param prefix [String] the indentation and list marker.
      # @param quote [String] `"` or `'` or `""`.
      # @param ids [Array<String>] ids to write.
      # @param suffix [String] the original trailing comment, spaces included.
      # @param ending [String] the original line ending, or `""`.
      # @return [Array<String>]
      def render_lines(prefix, quote, ids, suffix, ending)
        last = ids.size - 1
        ids.each_with_index.map do |id, i|
          tail = i.zero? ? suffix : ""
          mark = if i == last
                   ending
                 else
                   ending.empty? ? "\n" : ending
                 end
          "#{prefix}#{quote}#{id}#{quote}#{tail}#{mark}"
        end
      end
    end
  end
end
