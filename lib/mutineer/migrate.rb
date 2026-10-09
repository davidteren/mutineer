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
  # reorder keys. Only a bare id inside `ignore:` is replaced. A flow list may
  # span lines. A scalar changes only when its whole value is an id. A block
  # scalar under `ignore:` raises ArgumentError. A `{ id:, reason: }` entry is
  # left as written. A baseline file is never read.
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
    # A flow list may span lines. Only a scalar whose whole value is an id
    # changes. A block scalar under `ignore:` raises ArgumentError, and so
    # does a flow list this rewrite cannot read safely. The caller writes
    # nothing in that case.
    #
    # @param text [String] the `.mutineer.yml` contents.
    # @param current [Set<String>] new-format ids in this run.
    # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
    # @return [Outcome]
    # @raise [ArgumentError] when an `ignore:` shape cannot be rewritten safely.
    def self.rewrite(text, current, old_to_new)
      replacements = []
      unmapped = []
      lines = []
      pending = text.lines
      while (line = pending.shift)
        case line_kind(line)
        when :flow
          lines << rewrite_flow(collect_flow(line, pending), current, old_to_new, replacements, unmapped)
        when :scalar
          lines.concat(rewrite_scalar(line, current, old_to_new, replacements, unmapped))
        when :block_scalar
          reject_block_scalar
        when :block
          lines << line
          lines.concat(rewrite_block(pending, current, old_to_new, replacements, unmapped))
        else
          lines << line
        end
      end
      Outcome.new(replacements: replacements, unmapped: unmapped, text: lines.join)
    end

    class << self
      private

      # A block-list item whose value is one bare id.
      ITEM = /\A([ \t]*-[ \t]+)(['"]?)([0-9a-f]{12})\2([ \t]*(?:\#.*)?)(\r?\n)?\z/

      # `ignore:` followed by one bare id on the same line.
      SCALAR = /\A(ignore:[ \t]*)(['"]?)([0-9a-f]{12})\2([ \t]*(?:\#.*)?)(\r?\n)?\z/

      # `ignore: |` or `ignore: >`, including chomp and indent markers.
      KEY_BLOCK_SCALAR = /\Aignore:[ \t]*[|>]/

      # A list item whose value is a block scalar, such as `- |`.
      ITEM_BLOCK_SCALAR = /\A[ \t]*-[ \t]+[|>]/

      # An indented `|` or `>` that is the whole `ignore:` value.
      VALUE_BLOCK_SCALAR = /\A[ \t]+[|>]/

      # Told to the user when `ignore:` is a YAML block scalar. Exit 2.
      BLOCK_SCALAR_MESSAGE = "a block scalar under ignore: is not supported. " \
                             "Write ignore as a list of ids, one per line."

      # Told to the user when a flow `ignore:` list cannot be rewritten safely.
      FLOW_UNSUPPORTED_MESSAGE = "this ignore: flow list is not supported. " \
                                 "Write ignore as a list of ids, one per line."

      # Told to the user when `ignore: [` never finds its closing bracket.
      UNCLOSED_FLOW_MESSAGE = "an ignore: flow list has no closing ]. " \
                              "Write ignore as a list of ids, one per line."

      # Which `ignore:` shape this line opens, or nil when it is some other line.
      #
      # @param line [String] one line of the file, its terminator included.
      # @return [Symbol, nil] `:flow`, `:block_scalar`, `:block`, `:scalar`, or nil.
      def line_kind(line)
        return :flow if line.match?(/\Aignore:[ \t]*\[/)
        return :block_scalar if line.match?(KEY_BLOCK_SCALAR)
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

      # Lines from `ignore: [` through the line that closes the flow list.
      # Quotes and comments do not hide the closing bracket, and they do not
      # supply a false one.
      #
      # @param line [String] the opening line, its terminator included.
      # @param pending [Array<String>] the lines still to read.
      # @return [String] the whole flow value, newlines included.
      # @raise [ArgumentError] when the closing bracket is missing.
      def collect_flow(line, pending)
        chunk = line.dup
        return chunk if matching_index(chunk, chunk.index("["), "[", "]")

        while (next_line = pending.shift)
          chunk << next_line
          return chunk if matching_index(chunk, chunk.index("["), "[", "]")
        end
        raise ArgumentError, UNCLOSED_FLOW_MESSAGE
      end

      # Index of the `closer` that matches the `opener` at `start`, or nil.
      # Quoted text and comments are not structure.
      #
      # @param text [String]
      # @param start [Integer] index of the opening bracket.
      # @param opener [String] `[` or `{`.
      # @param closer [String] `]` or `}`.
      # @return [Integer, nil]
      def matching_index(text, start, opener, closer)
        index = start + 1
        depth = 1
        state = :plain
        while index < text.length
          char = text[index]
          case state
          when :plain
            if char == "'"
              state = :single
            elsif char == '"'
              state = :double
            elsif comment_at?(text, index)
              newline = text.index("\n", index)
              return nil unless newline

              index = newline + 1
              next
            elsif char == opener
              depth += 1
            elsif char == closer
              depth -= 1
              return index if depth.zero?
            end
          when :single
            if char == "'"
              if text[index + 1] == "'"
                index += 1
              else
                state = :plain
              end
            end
          when :double
            if char == "\\"
              return nil if index + 1 >= text.length

              index += 1
            elsif char == '"'
              state = :plain
            end
          end
          index += 1
        end
        nil
      end

      # Whether `index` starts a YAML comment. A `#` inside a token does not.
      #
      # @param text [String]
      # @param index [Integer]
      # @return [Boolean]
      def comment_at?(text, index)
        return false unless text[index] == "#"

        index.zero? || text[index - 1].match?(/\s/)
      end

      # Rewrites whole id scalars between the brackets of a flow list.
      # The list may span lines. A scalar that only contains an id is kept.
      # A `{ ... }` entry is kept. Nested lists and other shapes raise.
      #
      # @param chunk [String] `ignore: [` through the closing bracket.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] bare ids that matched nothing.
      # @return [String] the text to write.
      # @raise [ArgumentError] when the list is not a flat list of scalars.
      def rewrite_flow(chunk, current, old_to_new, replacements, unmapped)
        open = chunk.index("[")
        close = matching_index(chunk, open, "[", "]")
        raise ArgumentError, UNCLOSED_FLOW_MESSAGE unless close

        inner = rewrite_flow_items(chunk[(open + 1)...close], current, old_to_new, replacements, unmapped)
        "#{chunk[0..open]}#{inner}#{chunk[close..]}"
      end

      # Rewrites the text between the flow brackets.
      #
      # @param inner [String] text between `[` and `]`.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] bare ids that matched nothing.
      # @return [String]
      # @raise [ArgumentError] when an entry is not a scalar or a `{ ... }` entry.
      def rewrite_flow_items(inner, current, old_to_new, replacements, unmapped)
        out = +""
        index = 0
        while index < inner.length
          char = inner[index]
          if char.match?(/\s/) || char == ","
            out << char
            index += 1
          elsif comment_at?(inner, index)
            newline = inner.index("\n", index) || inner.length
            out << inner[index...newline]
            index = newline
          else
            raw, next_index = read_flow_item(inner, index)
            raise ArgumentError, FLOW_UNSUPPORTED_MESSAGE if next_index <= index

            out << replace_flow_scalar(raw, current, old_to_new, replacements, unmapped)
            index = next_index
          end
        end
        out
      end

      # One flow entry starting at `index`: a quoted scalar, a plain scalar,
      # or a `{ ... }` entry copied whole.
      #
      # @param text [String]
      # @param index [Integer]
      # @return [Array(String, Integer)] the raw entry and the index after it.
      # @raise [ArgumentError] when the entry is not one of those shapes.
      def read_flow_item(text, index)
        case text[index]
        when "'" then read_single_quoted(text, index)
        when '"' then read_double_quoted(text, index)
        when "{" then read_wrapped(text, index, "{", "}")
        when "[", "|", ">", "!", "&", "*", "?"
          raise ArgumentError, FLOW_UNSUPPORTED_MESSAGE
        else
          read_plain(text, index)
        end
      end

      # A single-quoted scalar, including its quotes. `''` is an escaped quote.
      #
      # @param text [String]
      # @param start [Integer] index of the opening quote.
      # @return [Array(String, Integer)]
      # @raise [ArgumentError] when the quote does not close.
      def read_single_quoted(text, start)
        index = start + 1
        while index < text.length
          if text[index] == "'"
            if text[index + 1] == "'"
              index += 2
              next
            end
            return [text[start..index], index + 1]
          end
          index += 1
        end
        raise ArgumentError, FLOW_UNSUPPORTED_MESSAGE
      end

      # A double-quoted scalar, including its quotes. Backslash escapes are
      # skipped so they cannot end the scalar early.
      #
      # @param text [String]
      # @param start [Integer] index of the opening quote.
      # @return [Array(String, Integer)]
      # @raise [ArgumentError] when the quote does not close.
      def read_double_quoted(text, start)
        index = start + 1
        while index < text.length
          char = text[index]
          if char == "\\"
            raise ArgumentError, FLOW_UNSUPPORTED_MESSAGE if index + 1 >= text.length

            index += 2
            next
          end
          return [text[start..index], index + 1] if char == '"'

          index += 1
        end
        raise ArgumentError, FLOW_UNSUPPORTED_MESSAGE
      end

      # The `{ ... }` or other wrapped entry starting at `start`, copied whole.
      #
      # @param text [String]
      # @param start [Integer] index of the opener.
      # @param opener [String]
      # @param closer [String]
      # @return [Array(String, Integer)]
      # @raise [ArgumentError] when the closer is missing.
      def read_wrapped(text, start, opener, closer)
        stop = matching_index(text, start, opener, closer)
        raise ArgumentError, FLOW_UNSUPPORTED_MESSAGE unless stop

        [text[start..stop], stop + 1]
      end

      # A plain flow scalar. It ends at a comma, a comment, or a line break.
      # A colon means the entry may be a mapping, which this rewrite does not
      # split safely.
      #
      # @param text [String]
      # @param start [Integer]
      # @return [Array(String, Integer)]
      # @raise [ArgumentError] when the entry is not a plain scalar.
      def read_plain(text, start)
        index = start
        while index < text.length
          char = text[index]
          break if char == "," || char == "\n" || char == "\r"
          break if comment_at?(text, index)
          if char == ":" || char == "[" || char == "]" || char == "{" || char == "}" ||
             char == "'" || char == '"'
            raise ArgumentError, FLOW_UNSUPPORTED_MESSAGE
          end

          index += 1
        end
        [text[start...index], index]
      end

      # The quote, the id, and the gaps around it when `raw` is exactly one id.
      # Nil when `raw` is any other scalar.
      #
      # @param raw [String] one flow entry, quotes included.
      # @return [Array(String, String, String, String), nil]
      def flow_scalar_id(raw)
        if (match = raw.match(/\A([0-9a-f]{12})([ \t]*)\z/))
          return ["", match[1], "", match[2]]
        end
        if raw.start_with?("'") && raw.end_with?("'")
          value = raw[1..-2].gsub("''", "'")
          return ["'", value, "", ""] if value.match?(/\A[0-9a-f]{12}\z/)
        end
        if raw.start_with?('"') && raw.end_with?('"')
          value = raw[1..-2]
          # A backslash can hide an id. Do not guess the decoded text.
          raise ArgumentError, FLOW_UNSUPPORTED_MESSAGE if value.include?("\\")

          return ['"', value, "", ""] if value.match?(/\A[0-9a-f]{12}\z/)
        end
        nil
      end

      # Replaces `raw` when its whole scalar value is an id. Several new ids
      # become several entries. Any other entry is returned unchanged.
      #
      # @param raw [String] one flow entry.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] bare ids that matched nothing.
      # @return [String]
      def replace_flow_scalar(raw, current, old_to_new, replacements, unmapped)
        parts = flow_scalar_id(raw)
        return raw unless parts

        quote, value, lead, trail = parts
        ids = mapped_ids(value, current, old_to_new, replacements, unmapped)
        return raw if ids == [value]

        "#{lead}#{ids.map { |id| "#{quote}#{id}#{quote}" }.join(", ")}#{trail}"
      end

      # The lines of a block-style `ignore:` value. A block scalar here is
      # rejected. A `{ id:, reason: }` entry is left to {rewrite_item}.
      #
      # @param pending [Array<String>] the lines still to read.
      # @param current [Set<String>] new-format ids in this run.
      # @param old_to_new [Hash{String => Array<String>}] old id => new ids.
      # @param replacements [Array<Replacement>] recorded changes.
      # @param unmapped [Array<String>] bare ids that matched nothing.
      # @return [Array<String>]
      # @raise [ArgumentError] when the value or a list item is a block scalar.
      def rewrite_block(pending, current, old_to_new, replacements, unmapped)
        written = []
        saw_entry = false
        while (next_line = pending.first) && inside_block?(next_line)
          raise ArgumentError, BLOCK_SCALAR_MESSAGE if block_scalar_entry?(next_line, saw_entry)

          saw_entry = true if next_line.match?(/\A[ \t]*[^ \t#\r\n]/)
          written.concat(rewrite_item(pending.shift, current, old_to_new, replacements, unmapped))
        end
        written
      end

      # Rejects a block scalar `ignore:` value. The constant lives on this
      # singleton, so {rewrite} calls this method instead of reading it.
      #
      # @return [void]
      # @raise [ArgumentError] always.
      def reject_block_scalar
        raise ArgumentError, BLOCK_SCALAR_MESSAGE
      end

      # Whether `line` is a block scalar used as the ignore value or as one
      # list item. A `|` under a later key, such as `reason: |`, is not.
      #
      # @param line [String]
      # @param saw_entry [Boolean] true after the first real entry in the value.
      # @return [Boolean]
      def block_scalar_entry?(line, saw_entry)
        line.match?(ITEM_BLOCK_SCALAR) || (!saw_entry && line.match?(VALUE_BLOCK_SCALAR))
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
