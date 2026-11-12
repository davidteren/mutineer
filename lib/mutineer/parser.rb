# frozen_string_literal: true

require "prism"

module Mutineer
  # Raised only for I/O failures while reading a source file.
  #
  # Prism syntax errors are NOT raised — they are in-band via ParseResult#errors.
  class ParseError < StandardError; end

  # Thin boundary around Prism.
  #
  # The parse methods return a Prism::ParseResult so all callers use
  # result.value, result.source.source (raw bytes), and result.errors
  # uniformly. No wrapping struct.
  class Parser
    # Parses a file with Prism.
    #
    # @param path [String] source file path.
    # @return [Prism::ParseResult] Prism parse result.
    # @raise [Mutineer::ParseError] when file I/O fails.
    def self.parse_file(path)
      Prism.parse_file(path)
    rescue SystemCallError => e
      raise ParseError, e.message
    end

    # Bytes of a magic comment Prism needs: the first line, or the second
    # when the first is a shebang. A longer line is cut. Real encoding
    # comments are short; the cap only bounds a pathological line.
    HEADER_BYTES = 4096

    # Reads a Ruby source file in the encoding its magic comment names, or
    # UTF-8 when it names none (#346). The bytes are not transcoded, so
    # Prism's offsets still address them and a mutant written back stays
    # valid for that encoding. An unknown encoding name stays UTF-8, as
    # Prism does. I/O errors propagate (`Errno::ENOENT` and the rest).
    #
    # @param path [String] source file path.
    # @return [String] source text, tagged with its encoding.
    def self.read(path)
      bytes = File.binread(path)
      bytes.force_encoding(source_encoding(bytes))
    end

    # Encoding Ruby assigns to `bytes` from its magic comment.
    #
    # This follows Ruby's loader, not Prism. Prism 2 treats `# encoding=NAME`
    # with no space as a magic comment. Ruby 3.4 does not, and loads that
    # file as UTF-8 (#346).
    #
    # @param bytes [String] file contents.
    # @return [Encoding]
    def self.source_encoding(bytes)
      name = magic_name(header(bytes))
      return Encoding::UTF_8 if name.nil?

      Encoding.find(name)
    rescue ArgumentError
      Encoding::UTF_8
    end
    private_class_method :source_encoding

    # The encoding name in `header`, or nil. A colon may have no space
    # (`encoding: EUC-JP`). An equals sign needs whitespace on both sides
    # (`encoding = EUC-JP`). A vim modeline counts only as `set fileencoding=`.
    #
    # @param header [String] the first line, plus the second after a shebang.
    # @return [String, nil]
    def self.magic_name(header)
      text = header.to_s
      vim = text.match(/vim:\s*set\b[^\n\r]*\bfileencoding\s*=\s*([^\s:]+)/i)
      return vim[1] if vim

      named = text.match(/\b(?:en)?coding\s*:\s*([^\s;#]+)/i) ||
              text.match(/\b(?:en)?coding\s+=\s*([^\s;#]+)/i)
      named&.[](1)
    end
    private_class_method :magic_name

    # The first line of `bytes`, plus the second when the first is a shebang.
    #
    # @param bytes [String] file contents.
    # @return [String] a binary slice.
    def self.header(bytes)
      slice = bytes.byteslice(0, HEADER_BYTES)
      return "".b if slice.nil?

      slice = slice.b
      line_end = slice.index("\n") || slice.index("\r")
      return slice unless line_end

      first = slice.byteslice(0, line_end)
      return slice.byteslice(0, line_end + 1) unless first.start_with?("#!")

      rest_from = line_end + 1
      rest = slice.byteslice(rest_from..)
      return slice if rest.nil? || rest.empty?

      second_end = rest.index("\n") || rest.index("\r")
      return slice unless second_end

      slice.byteslice(0, rest_from + second_end + 1)
    end
    private_class_method :header

    # Parses source text with Prism.
    #
    # @param source [String] source text.
    # @return [Prism::ParseResult] Prism parse result.
    def self.parse_string(source)
      Prism.parse(source)
    end

    # True when Ruby cannot load `source`: the loaded Prism reports a parse
    # error and the running Ruby cannot compile the text either. Prism alone is
    # not enough. Prism 2 reports a bare-constant operator write inside a
    # method (`T += 1`) as a dynamic constant assignment, while the Prism 1
    # that Ruby 3.4 and 4.0 load files with accepts it (#392). Compiling does
    # not run the code.
    #
    # @param source [String] source text.
    # @return [Boolean]
    def self.invalid?(source)
      return false if parse_string(source).errors.empty? # the usual case costs one parse

      !compiles?(source)
    end

    # Serializes {.compiles?}: it swaps the process-wide `$VERBOSE`, and
    # `--daemon` checks mutants on several threads.
    COMPILE_LOCK = Mutex.new

    # Whether the running Ruby compiles `source`, without running it. Mutineer
    # forks, so it runs on CRuby, which has RubyVM. Warnings are off for the
    # compile: a mutant can trigger one (`if a = 1`).
    #
    # @param source [String] source text.
    # @return [Boolean]
    def self.compiles?(source)
      COMPILE_LOCK.synchronize do
        verbose = $VERBOSE
        $VERBOSE = nil
        RubyVM::InstructionSequence.compile(source)
        true
      rescue SyntaxError
        false
      ensure
        $VERBOSE = verbose
      end
    end
    private_class_method :compiles?

    # The comments of source text, without building its syntax tree: a few
    # times cheaper than {.parse_string} for a caller that needs only these.
    #
    # @param source [String] source text.
    # @return [Array<Prism::Comment>] its comments, in source order.
    def self.comments(source)
      Prism.parse_comments(source)
    end
  end
end
