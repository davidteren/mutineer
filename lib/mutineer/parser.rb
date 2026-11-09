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
    # after it moves by the length change, and one that encloses it keeps its
    # start and moves its end (an edit inside `T += 1`, which Prism 2 marks
    # whole). When the edit keeps the original's edited text whole and only
    # wraps it (condition negation turns `T += 1` into `!(T += 1)`), an error
    # wholly inside the edit maps back through that kept text. Any other error
    # that overlaps the edit is new. The mutant adds an error unless each of
    # its errors maps onto the same error (message and offsets) in the original.
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
      # Where the original's edited text sits, unchanged, inside the new text:
      # nil unless the edit only wraps it.
      kept = mutated.byteslice(head...edit_end).byteindex(original.byteslice(head...(original.bytesize - tail)))
      # An error at a boundary can fit more than one place: after a deletion,
      # an error that ends where the edit starts may lie before it or enclose
      # it (`C = [a].map { }` to `C = [a]`). Each fit is a candidate.
      candidates = errors.map do |error|
        from = error.location.start_offset
        to = error.location.end_offset
        fits = []
        fits << [from, to] if to <= head
        fits << [from + shift, to + shift] if from >= edit_end
        fits << [from, to + shift] if from <= head && to >= edit_end
        fits << [from - kept, to - kept] if kept && from >= head && to <= edit_end
        return true if fits.empty? # the error overlaps text the edit changed

        fits.map { |start, finish| [error.message, start, finish] }
      end
      baseline = parse_string(original).errors.map { |e| [e.message, e.location.start_offset, e.location.end_offset] }.tally
      # shortcut: the first fit still free wins, so two same-message boundary
      # errors that compete for one fit match in candidate order; switch to a
      # full matching if a real case ever needs it.
      candidates.each do |fits|
        match = fits.find { |fit| baseline.fetch(fit, 0).positive? }
        return true unless match

        baseline[match] -= 1
      end
      false
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
