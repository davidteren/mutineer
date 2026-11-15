# frozen_string_literal: true

module Mutineer
  # DATABASE_URL values stored in a project's dotenv files. The tool process
  # does not see a URL the app loads itself during boot. Reading the files
  # lets redaction hide that password (#341). Stdlib only, so the app-side
  # daemon can load this file.
  module DatabaseUrls
    # Files dotenv-rails reads. Later files override at runtime. Every value
    # is kept: hiding a password the running app did not use is safe.
    FILE_NAMES = %w[
      .env
      .env.local
      .env.development
      .env.development.local
      .env.test
      .env.test.local
    ].freeze
    module_function

    # DATABASE_URL values from the dotenv files under `root`. Missing files
    # add nothing. An unreadable file adds nothing: a permission error must
    # not stop a run. Estimate: a project dotenv file is readable by the user
    # who starts the run.
    #
    # @param root [String, nil] project directory.
    # @return [Array<String>]
    def from_files(root)
      return [] if root.nil? || root.empty?

      FILE_NAMES.flat_map { |name| from_file(File.join(root, name)) }.uniq
    end

    # DATABASE_URL values in one file. Every line is read. A double-quoted
    # value may continue on later lines until its closing quote. A quote that
    # never closes is a plain value on its own line, as in dotenv. `${NAME}` and
    # `$NAME` expand from an earlier assignment in the file, or from the
    # environment when that variable is already set. A backslash before `$`
    # is a literal dollar. A single-quoted value is not expanded. An invalid
    # byte is replaced and does not stop the read. A directory, a missing
    # path, and an unreadable file add nothing. An unknown `$NAME` is left as
    # written, so that reference does not become a password.
    #
    # @param path [String]
    # @return [Array<String>]
    def from_file(path)
      return [] unless File.file?(path)

      vars = {}
      urls = []
      lines = File.open(path, "rb") { |io| io.each_line.map { |line| utf8_line(line) } }
      index = 0
      while index < lines.size
        stop = index
        chunk = lines[index]
        parsed = parse_assignment(chunk)
        while parsed == :open && stop + 1 < lines.size
          stop += 1
          chunk += lines[stop]
          parsed = parse_assignment(chunk)
        end
        if parsed == :open
          # A quote that never closes: dotenv reads that line as a plain
          # value, and the lines after it as their own assignments.
          stop = index
          parsed = parse_assignment(lines[index], plain: true)
        end
        index = stop + 1
        next unless parsed.is_a?(Array)

        key, raw, expand_value = parsed
        value = expand_value ? expand(raw, vars) : raw
        vars[key] = value
        urls << value if key == "DATABASE_URL" && !value.empty?
      end
      urls
    rescue SystemCallError
      []
    end

    # The DATABASE_URL value on one dotenv line, or nil when the line is a
    # comment, another key, or an empty value.
    #
    # @param line [String]
    # @return [String, nil]
    def line_url(line)
      parsed = parse_assignment(line)
      return nil unless parsed.is_a?(Array) && parsed[0] == "DATABASE_URL"

      parsed[1].empty? ? nil : parsed[1]
    end

    # One `KEY=value` assignment. The third element is false for a
    # single-quoted value, which dotenv does not expand. `:open` means a
    # quoted value has not reached its closing quote yet. `plain` reads a
    # leading quote as part of an unquoted value.
    #
    # @param line [String]
    # @param plain [Boolean]
    # @return [Array(String, String, Boolean), Symbol, nil]
    def parse_assignment(line, plain: false)
      text = utf8_line(line).sub(/\A\uFEFF/, "").strip
      return nil if text.empty? || text.start_with?("#")

      text = text.sub(/\Aexport\s+/, "")
      match = text.match(/\A([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/m)
      return nil unless match

      key = match[1]
      raw = match[2]
      if !plain && raw.start_with?("'")
        stop = closing_quote(raw, "'")
        return :open unless stop

        [key, raw[1...stop], false]
      elsif !plain && raw.start_with?('"')
        stop = closing_quote(raw, '"')
        return :open unless stop

        [key, decode_double(raw[1...stop]), true]
      else
        [key, raw.sub(/\s+#.*\z/, "").strip, true]
      end
    end

    # Replace `${NAME}` and `$NAME`. A backslash before `$` stays a dollar and
    # is not a reference. The environment wins over an earlier assignment in
    # the file. Anything else is left as written.
    #
    # @param value [String]
    # @param vars [Hash{String => String}]
    # @return [String]
    def expand(value, vars)
      value.gsub(/\\\$|\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/) do
        match = Regexp.last_match
        next "$" if match[0] == "\\$"

        name = match[1] || match[2]
        if ENV.key?(name)
          ENV[name].to_s
        elsif vars.key?(name)
          vars[name]
        else
          match[0]
        end
      end
    end

    # One line as UTF-8. An invalid byte becomes U+FFFD so a binary dotenv
    # line cannot raise before redaction starts.
    #
    # @param line [String]
    # @return [String]
    def utf8_line(line)
      text = line.to_s.dup
      text.force_encoding(Encoding::UTF_8)
      text.scrub
    end

    # Index of the closing quote. A backslash escapes the next character
    # inside double quotes, so `\"` does not end the value.
    #
    # @param raw [String]
    # @param quote [String]
    # @return [Integer, nil]
    def closing_quote(raw, quote)
      index = 1
      while index < raw.length
        if quote == '"' && raw[index] == "\\"
          index += 2
        elsif raw[index] == quote
          return index
        else
          index += 1
        end
      end
      nil
    end

    # Double-quoted dotenv escapes this reader understands. Other backslashes
    # stay as written.
    #
    # @param text [String]
    # @return [String]
    def decode_double(text)
      text.gsub(/\\[nrt"\\]/, "\\n" => "\n", "\\r" => "\r", "\\t" => "\t", "\\\"" => '"', "\\\\" => "\\")
    end
  end
end
