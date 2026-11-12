# frozen_string_literal: true

module Mutineer
  # Bytes to write for a mutant file so they match its magic comment.
  #
  # The in-process string is already in that encoding. The daemon receives
  # the same text through JSON, which turns it into UTF-8. Writing those
  # UTF-8 bytes under an `encoding: EUC-JP` comment would make Ruby misread
  # the file. This encodes the text back to the comment's encoding. No
  # Prism: the daemon loads on the app's Ruby (#346).
  module SourceBytes
    # First line, or the second when the first is a shebang. CRLF is one
    # ending: the carriage return is not a separate line.
    MAGIC = /\A(?:#![^\n\r]*(?:\r\n|\n|\r))?#[^\n\r]*(?:en)?coding[:=]\s*([^\s;#]+)/i

    # `code` as the bytes its magic comment names, or its own bytes when it
    # names none or an unknown encoding.
    #
    # @param code [String] mutant source, in its encoding or in UTF-8.
    # @return [String] binary string of the bytes to write.
    def self.for_file(code)
      text = code.to_s
      name = text.match(MAGIC)&.[](1)
      encoded = encode(text, name)
      encoded.b
    end

    # `text` in `name`'s encoding, or `text` when that encoding is unknown
    # or cannot hold a character.
    #
    # @param text [String]
    # @param name [String, nil]
    # @return [String]
    def self.encode(text, name)
      return text if name.nil? || name.empty?

      encoding = Encoding.find(name)
      return text if encoding == text.encoding

      text.encode(encoding)
    rescue ArgumentError, Encoding::UndefinedConversionError
      text
    end
    private_class_method :encode
  end
end
