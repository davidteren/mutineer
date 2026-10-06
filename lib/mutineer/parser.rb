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

    # Parses source text with Prism.
    #
    # @param source [String] source text.
    # @return [Prism::ParseResult] Prism parse result.
    def self.parse_string(source)
      Prism.parse(source)
    end

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
