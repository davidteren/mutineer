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

    # True when `mutated` has a parse error that `original` does not have. A
    # file can carry an error Ruby itself still loads: Prism 2 reports a
    # bare-constant operator write inside a method (`T += 1`) as a dynamic
    # constant assignment, as Ruby's parse.y does, while the Prism 1 that
    # Ruby 3.4 and 4.0 load with accepts it. Such an error must not make
    # every mutant of the file invalid.
    #
    # The edit is the span between the bytes both texts share at the start and
    # at the end. A mutant error wholly before it keeps its offsets, one wholly
    # after it moves by the length change, and one that touches it is new. The
    # mutant adds an error unless each of its errors maps onto the same error
    # (message and offsets) in the original.
    #
    # @param original [String] the source before the edit.
    # @param mutated [String] the source after the edit.
    # @return [Boolean]
    def self.new_errors?(original, mutated)
      errors = parse_string(mutated).errors
      return false if errors.empty? # the usual case costs one parse, as before

      head, tail = shared_ends(original, mutated)
      shift = original.bytesize - mutated.bytesize
      edit_end = mutated.bytesize - tail
      mapped = errors.map do |error|
        from = error.location.start_offset
        to = error.location.end_offset
        if to <= head then [error.message, from, to]
        elsif from >= edit_end then [error.message, from + shift, to + shift]
        else return true # the error touches the edit
        end
      end
      baseline = parse_string(original).errors.map { |e| [e.message, e.location.start_offset, e.location.end_offset] }.tally
      mapped.tally.any? { |error, count| count > baseline.fetch(error, 0) }
    end

    # The byte lengths of the longest shared start and the longest shared end
    # of two texts, which never overlap.
    #
    # @param left [String]
    # @param right [String]
    # @return [Array(Integer, Integer)]
    def self.shared_ends(left, right)
      limit = [left.bytesize, right.bytesize].min
      head = 0
      head += 1 while head < limit && left.getbyte(head) == right.getbyte(head)
      tail = 0
      tail += 1 while tail < limit - head && left.getbyte(-1 - tail) == right.getbyte(-1 - tail)
      [head, tail]
    end
    private_class_method :shared_ends

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
