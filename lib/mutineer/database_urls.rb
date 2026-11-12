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
    # Bytes read from one file. A dotenv file is a few kilobytes; a file past
    # this is not one. The first megabyte is still scanned, so a DATABASE_URL
    # near the top is kept. Estimate: none of the apps this suite runs has a
    # dotenv file this large.
    MAX_BYTES = 1_048_576

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

    # DATABASE_URL values in one file. A directory, a missing path, and a
    # file that is not valid text add nothing.
    #
    # @param path [String]
    # @return [Array<String>]
    def from_file(path)
      return [] unless File.file?(path)

      data = File.open(path, "rb") { |io| io.read(MAX_BYTES) }
      return [] if data.nil? || data.empty?

      data.force_encoding(Encoding::UTF_8).scrub.each_line.filter_map { |line| line_url(line) }
    rescue SystemCallError
      []
    end

    # The DATABASE_URL value on one dotenv line, or nil when the line is a
    # comment, another key, or an empty value.
    #
    # @param line [String]
    # @return [String, nil]
    def line_url(line)
      text = line.to_s.sub(/\A\uFEFF/, "").strip
      return nil if text.empty? || text.start_with?("#")

      text = text.sub(/\Aexport\s+/, "")
      return nil unless text.match?(/\ADATABASE_URL\s*=/)

      unquote(text.sub(/\ADATABASE_URL\s*=\s*/, ""))
    end

    # The value after `=`, with matching quotes removed. An unquoted value
    # drops a trailing ` # comment`. An unclosed quote is not a value.
    #
    # @param raw [String]
    # @return [String, nil]
    def unquote(raw)
      if raw.start_with?('"')
        stop = closing_quote(raw, '"')
        return nil unless stop

        value = decode_double(raw[1...stop])
        value.empty? ? nil : value
      elsif raw.start_with?("'")
        stop = closing_quote(raw, "'")
        return nil unless stop

        value = raw[1...stop]
        value.empty? ? nil : value
      else
        value = raw.sub(/\s+#.*\z/, "").strip
        value.empty? ? nil : value
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
