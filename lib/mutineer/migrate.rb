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
  # reorder keys. A bare id, and the `id` inside an `ignore:` mapping, are
  # replaced. The reason, the quotes, and the comments stay. A baseline file
  # is never read.
  module Migrate
    # One old id and the new ids that replace it, in collection order.
    Replacement = Data.define(:old_id, :new_ids)

    # The outcome of rewriting one file in memory. `text` is what to write.
    # It equals the input when nothing changed. `unmapped` holds ids that
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
            lines.concat(rewrite_entry(pending, current, old_to_new, replacements, unmapped))
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

      # The `id:` token inside an ignore mapping, with its quotes and spacing.
      MAPPING_ID = /\A([ \t]*(?:-[ \t]+)?(?:\{[ \t]*)?id:[ \t]*)(['"]?)([0-9a-f]{12})\2/

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
      # @param unmapped [Array<String>] ids that matched nothing.
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

      # Rewrites ids between the brackets of a one-line flow list.
      # A `{id:, reason:}` item is rewritten as a mapping. A bare id stays a bare id.
      #
      # @param line [String] an `ignore: [...]` line.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] ids that matched nothing.
      # @return [String] the line to write.
      def rewrite_flow(line, current, old_to_new, replacements, unmapped)
        match = line.match(/\A(ignore:[ \t]*\[)(.*?)(\].*)\z/m)
        return line unless match

        inner = split_flow_items(match[2]).map do |item|
          rewrite_flow_item(item, current, old_to_new, replacements, unmapped)
        end.join(",")
        "#{match[1]}#{inner}#{match[3]}"
      end

      # Splits one flow-list body on commas that are outside braces, brackets, and quotes.
      #
      # @param inner [String] the text between the flow list's brackets.
      # @return [Array<String>] one item per comma, spacing kept on each item.
      def split_flow_items(inner)
        items = []
        current_item = +""
        depth = 0
        quote = nil
        inner.each_char do |char|
          if quote
            current_item << char
            quote = nil if char == quote
          elsif char == "'" || char == '"'
            quote = char
            current_item << char
          elsif char == "{" || char == "["
            depth += 1
            current_item << char
          elsif (char == "}" || char == "]") && depth.positive?
            depth -= 1
            current_item << char
          elsif char == "," && depth.zero?
            items << current_item
            current_item = +""
          else
            current_item << char
          end
        end
        items << current_item unless current_item.empty? && items.empty?
        items
      end

      # Rewrites one flow-list item. A mapping that expands to several ids
      # becomes several mappings, joined by a comma and a space.
      #
      # @param item [String] one flow-list item, leading space included.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] ids that matched nothing.
      # @return [String] the item text to write.
      def rewrite_flow_item(item, current, old_to_new, replacements, unmapped)
        id_match = MAPPING_ID.match(item)
        if id_match
          ids = mapped_ids(id_match[3], current, old_to_new, replacements, unmapped)
          return ids.map { |new_id| item.sub(MAPPING_ID, "#{id_match[1]}#{id_match[2]}#{new_id}#{id_match[2]}") }.join(", ")
        end

        item.gsub(ID_TOKEN) do
          quote = Regexp.last_match(1)
          ids = mapped_ids(Regexp.last_match(2), current, old_to_new, replacements, unmapped)
          ids.map { |new_id| "#{quote}#{new_id}#{quote}" }.join(", ")
        end
      end

      # Rewrites a one-line `ignore: <id>`. Several new ids become a block list,
      # so each id stays a bare string. The comment stays on the key line.
      #
      # @param line [String] an `ignore: <id>` line.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] ids that matched nothing.
      # @return [Array<String>] the lines to write.
      def rewrite_scalar(line, current, old_to_new, replacements, unmapped)
        match = SCALAR.match(line)
        unless match
          return rewrite_scalar_mapping(line, current, old_to_new, replacements, unmapped)
        end

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

      # Rewrites `ignore: {id:, reason:}` on one line. One new id stays on
      # that line. Several new ids become a block list, so the file does not
      # gain a second `ignore:` key.
      #
      # @param line [String] an `ignore:` line that is not a bare id.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] ids that matched nothing.
      # @return [Array<String>] the lines to write.
      def rewrite_scalar_mapping(line, current, old_to_new, replacements, unmapped)
        match = line.match(/\A(ignore:[ \t]*)(\{.*\})([ \t]*(?:\#.*)?)(\r?\n)?\z/)
        return [line] unless match

        body = match[2]
        id_match = MAPPING_ID.match(body)
        return [line] unless id_match

        ids = mapped_ids(id_match[3], current, old_to_new, replacements, unmapped)
        written = ids.map { |new_id| body.sub(MAPPING_ID, "#{id_match[1]}#{id_match[2]}#{new_id}#{id_match[2]}") }
        comment = match[3]
        ending = match[4].to_s
        if written.size == 1
          ["#{match[1]}#{written.first}#{comment}#{ending}"]
        else
          ending = "\n" if ending.empty?
          items = written.each_with_index.map do |item, index|
            mark = index == written.size - 1 ? ending : "\n"
            "  - #{item}#{mark}"
          end
          ["ignore:#{comment}#{ending}", *items]
        end
      end

      # Rewrites one block-list entry. A bare id stays a bare id. A mapping
      # keeps its reason, quotes, and comments, and expands to one mapping
      # per new id.
      #
      # @param pending [Array<String>] the unread lines, terminator included.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] ids that matched nothing.
      # @return [Array<String>] the lines to write.
      def rewrite_entry(pending, current, old_to_new, replacements, unmapped)
        line = pending.shift
        return [] if line.nil?
        return [line] if line.match?(/\A[ \t]*(?:\#.*)?\r?\n?\z/)
        return rewrite_item(line, current, old_to_new, replacements, unmapped) if ITEM.match?(line)
        return [line] unless line.match?(/\A[ \t]*-[ \t]/)

        dash_indent = line.index("-")
        block = [line]
        while (next_line = pending.first) && mapping_continuation?(next_line, dash_indent)
          block << pending.shift
        end
        rewrite_mapping(block, current, old_to_new, replacements, unmapped)
      end

      # True when `line` continues the mapping opened by a list item whose
      # dash sits at `dash_indent`. A new list item, a blank line, and a
      # comment at that indent do not.
      #
      # @param line [String] the next line.
      # @param dash_indent [Integer] column of the mapping's list dash.
      # @return [Boolean]
      def mapping_continuation?(line, dash_indent)
        return false if line.match?(/\A[ \t]*-[ \t]/)
        return false if line.match?(/\A[ \t]*\r?\n?\z/)

        line[/[ \t]*/].size > dash_indent
      end

      # Rewrites the `id` inside one mapping block. Calls {mapped_ids} once.
      # Each new id gets a copy of the block. Only the last copy keeps a
      # missing final newline.
      #
      # @param block [Array<String>] the mapping's lines, terminator included.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] ids that matched nothing.
      # @return [Array<String>] the lines to write.
      def rewrite_mapping(block, current, old_to_new, replacements, unmapped)
        index = block.index { |entry| MAPPING_ID.match?(entry) }
        return block unless index

        id_match = MAPPING_ID.match(block[index])
        ids = mapped_ids(id_match[3], current, old_to_new, replacements, unmapped)
        copies = ids.map do |new_id|
          copy = block.map(&:dup)
          copy[index] = copy[index].sub(MAPPING_ID, "#{id_match[1]}#{id_match[2]}#{new_id}#{id_match[2]}")
          copy
        end
        copies.each_with_index do |copy, copy_index|
          next if copy_index == copies.size - 1

          last = copy.last
          copy[-1] = "#{last}\n" unless last.end_with?("\n")
        end
        copies.flatten
      end

      # Rewrites one bare block-list item, or returns the line unchanged.
      #
      # @param line [String] one line inside an `ignore:` block.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] ids that matched nothing.
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
