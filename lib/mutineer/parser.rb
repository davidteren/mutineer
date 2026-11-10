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
