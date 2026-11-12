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

    # DATABASE_URL values in one file. Every line is read. `${NAME}` and
    # `$NAME` expand from an earlier assignment in the file, or from the
    # environment when that variable is already set. A single-quoted value is
    # not expanded. A directory, a missing path, and an unreadable file add
    # nothing. An unknown `$NAME` is left as written, so that reference does
    # not become a password.
    #
    # @param path [String]
    # @return [Array<String>]
    def from_file(path)
      return [] unless File.file?(path)

      vars = {}
      urls = []
      File.open(path, "rb") do |io|
        io.each_line do |line|
          parsed = parse_assignment(line)
          next unless parsed

          key, raw, expand_value = parsed
          value = expand_value ? expand(raw, vars) : raw
          vars[key] = value
          urls << value if key == "DATABASE_URL" && !value.empty?
        end
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
      return nil unless parsed && parsed[0] == "DATABASE_URL"

      parsed[1].empty? ? nil : parsed[1]
    end

    # One `KEY=value` assignment. The third element is false for a
    # single-quoted value, which dotenv does not expand.
    #
    # @param line [String]
    # @return [Array(String, String, Boolean), nil]
    def parse_assignment(line)
      text = line.to_s.sub(/\A\uFEFF/, "").strip
      return nil if text.empty? || text.start_with?("#")

      text = text.sub(/\Aexport\s+/, "")
      match = text.match(/\A([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/)
      return nil unless match

      key = match[1]
      raw = match[2]
      if raw.start_with?("'")
        stop = closing_quote(raw, "'")
        return nil unless stop

        [key, raw[1...stop], false]
      elsif raw.start_with?('"')
        stop = closing_quote(raw, '"')
        return nil unless stop

        [key, decode_double(raw[1...stop]), true]
      else
        [key, raw.sub(/\s+#.*\z/, "").strip, true]
      end
    end

    # Replace `${NAME}` and `$NAME`. The environment wins over an earlier
    # assignment in the file. Anything else is left as written.
    #
    # @param value [String]
    # @param vars [Hash{String => String}]
    # @return [String]
    def expand(value, vars)
      value.gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/) do
        name = Regexp.last_match(1) || Regexp.last_match(2)
        if ENV.key?(name)
          ENV[name].to_s
        elsif vars.key?(name)
          vars[name]
        else
          Regexp.last_match(0)
        end
      end
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
