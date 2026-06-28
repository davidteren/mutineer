# frozen_string_literal: true

require "prism"

module Mutineer
  # Raised only for I/O failures while reading a source file. Prism syntax
  # errors are NOT raised — they are in-band via ParseResult#errors.
  class ParseError < StandardError; end

  # Thin boundary around Prism. Both methods return a Prism::ParseResult so all
  # callers use result.value (AST root), result.source.source (raw bytes), and
  # result.errors uniformly. No wrapping struct.
  class Parser
    # Returns Prism::ParseResult. Re-raises I/O failures as Mutineer::ParseError.
    def self.parse_file(path)
      Prism.parse_file(path)
    rescue SystemCallError => e
      raise ParseError, e.message
    end

    # Returns Prism::ParseResult. Never raises; callers check .errors.empty?.
    def self.parse_string(source)
      Prism.parse(source)
    end
  end
end
