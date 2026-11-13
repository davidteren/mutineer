# frozen_string_literal: true

module Mutineer
  # Bytes to write for a mutant file so they match its magic comment.
  #
  # The in-process string is already in that encoding. The daemon receives
  # the same text through JSON, which turns it into UTF-8. Writing those
  # UTF-8 bytes under an `encoding: EUC-JP` comment would make Ruby misread
  # the file. This encodes the text back to the comment's encoding. No
  # Prism: the daemon loads on the app's Ruby (#346).
  #
  # The comment forms are Ruby's, not Prism's. Ruby ignores
  # `# encoding=NAME` with no space, and it ignores a coding word that is
  # not in a comment. Prism 2 accepts the first of those.
  module SourceBytes
    # How much of the file can hold the comment. Real comments are short.
    # The cap only bounds a pathological first line.
    HEADER_BYTES = 4096

    # `code` as the bytes its magic comment names, or its own bytes when it
    # names none or an unknown encoding. A snippet that is already in
    # another encoding and has no comment gets one, so `load` uses that
    # encoding. A redefine snippet is such a snippet (#346).
    #
    # @param code [String] mutant source, in its encoding or in UTF-8.
    # @return [String] binary string of the bytes to write.
    def self.for_file(code)
      text = code.to_s
      name = encoding_name(text)
      if name.nil? && foreign?(text)
        text = with_magic_comment(text)
        name = text.encoding.name
      end
      encode(text, name).b
    end

    # Encoding Ruby assigns to `bytes` from its magic comment, or UTF-8.
    #
    # @param bytes [String] file contents.
    # @return [Encoding]
    def self.encoding_for(bytes)
      name = encoding_name(bytes)
      return Encoding::UTF_8 if name.nil?

      Encoding.find(name)
    rescue ArgumentError
      Encoding::UTF_8
    end

    # The encoding name in the first comment line, or the second when the
    # first is a shebang. Nil when Ruby would ignore the line.
    #
    # @param code [String]
    # @return [String, nil]
    def self.encoding_name(code)
      first, second = header_lines(code)
      chosen = shebang?(first) ? second : first
      comment = comment_body(chosen)
      return nil if comment.nil?

      name_in(comment)
    end
    private_class_method :encoding_name

    # True when `text` holds characters UTF-8 would not already store.
    #
    # @param text [String]
    # @return [Boolean]
    def self.foreign?(text)
      return false if text.encoding == Encoding::UTF_8 || text.encoding == Encoding::US_ASCII

      !text.ascii_only?
    rescue ArgumentError
      true
    end
    private_class_method :foreign?

    # `text` with a magic comment naming its encoding.
    #
    # @param text [String]
    # @return [String]
    def self.with_magic_comment(text)
      comment = "# encoding: #{text.encoding.name}\n".dup.force_encoding(text.encoding)
      comment + text
    end
    private_class_method :with_magic_comment

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

    # The first line and the second, without their endings. CRLF is one
    # ending. Only the first {HEADER_BYTES} bytes are read.
    #
    # @param code [String]
    # @return [Array(String, String)]
    def self.header_lines(code)
      raw = code.to_s.b.byteslice(0, HEADER_BYTES) || "".b
      first, rest = take_line(raw)
      second, = take_line(rest)
      [first, second]
    end
    private_class_method :header_lines

    # One line and what follows it.
    #
    # @param raw [String] binary text.
    # @return [Array(String, String)]
    def self.take_line(raw)
      return ["", ""] if raw.nil? || raw.empty?

      crlf = raw.index("\r\n".b)
      lf = raw.index("\n".b)
      cr = raw.index("\r".b)
      if crlf && (lf.nil? || crlf <= lf) && (cr.nil? || crlf <= cr)
        [raw.byteslice(0, crlf), raw.byteslice((crlf + 2)..)]
      elsif lf && (cr.nil? || lf <= cr)
        [raw.byteslice(0, lf), raw.byteslice((lf + 1)..)]
      elsif cr
        [raw.byteslice(0, cr), raw.byteslice((cr + 1)..)]
      else
        [raw, ""]
      end
    end
    private_class_method :take_line

    # True when `line` is a shebang. Ruby then reads the encoding from the
    # next line.
    #
    # @param line [String]
    # @return [Boolean]
    def self.shebang?(line)
      line.to_s.b.start_with?("#!".b)
    end
    private_class_method :shebang?

    # `line` from its `#`, or nil when the line is code. Leading spaces
    # and tabs are allowed. A trailing comment on a code line is not.
    #
    # @param line [String, nil]
    # @return [String, nil] binary comment text.
    def self.comment_body(line)
      return nil if line.nil?

      raw = line.to_s.b
      index = 0
      index += 1 while raw.getbyte(index) == 32 || raw.getbyte(index) == 9
      return nil unless raw.getbyte(index) == 35

      raw.byteslice(index..)
    end
    private_class_method :comment_body

    # The encoding name in a comment line, or nil. A colon may have no
    # space. An equals sign needs whitespace on both sides. A vim modeline
    # counts only as `set fileencoding=`.
    #
    # @param comment [String]
    # @return [String, nil]
    def self.name_in(comment)
      text = comment.to_s.b
      vim = text.match(/vim:\s*set\b[^\n\r]*\bfileencoding\s*=\s*([^\s:]+)/i)
      return vim[1] if vim

      named = text.match(/\b(?:en)?coding\s*:\s*([^\s;#]+)/i) ||
              text.match(/\b(?:en)?coding\s+=\s*([^\s;#]+)/i)
      named&.[](1)
    rescue ArgumentError
      nil
    end
    private_class_method :name_in
  end
end
