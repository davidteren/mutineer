# frozen_string_literal: true

require "json"

module Mutineer
  # The line format a `--matrix` mutant child uses to tell its parent how each
  # test went: one JSON array per line, `["pass", file, name]` or
  # `["kill", file, name]`. The child writes each line when the test is
  # recorded, so a child killed at the timeout has already sent every kill it
  # saw. A skipped test sends nothing.
  #
  # Writing never raises: a recorder that broke the test run would change the
  # verdict, and the exit status alone decides the verdict. A lost line only
  # leaves the matrix row short.
  #
  # Stdlib-only, so the app-side daemon can load the files that require it.
  module KillChannel
    # Event for a test that passed against the mutant.
    PASS = "pass"

    # Event for a test that failed or errored against the mutant: it killed it.
    KILL = "kill"

    # Serializes writes from tests that record on several threads.
    LOCK = Mutex.new

    # Writes one event line.
    #
    # @param io [IO] the write end of the channel.
    # @param event [String] {PASS} or {KILL}.
    # @param file [String] the file that defines the test.
    # @param name [String] the test name, e.g. `CalculatorTest#test_add`.
    # @return [void]
    def self.write(io, event, file, name)
      line = "#{JSON.generate([event, utf8(file), utf8(name)])}\n"
      LOCK.synchronize { io.write(line) }
    rescue StandardError
      nil
    end

    # Reads the complete lines of `buffer`. A partial last line (the child was
    # killed while writing it) and a malformed line are dropped.
    #
    # @param buffer [String] bytes read from the channel.
    # @return [Array(Array<Array(String, String)>, Array<Array(String, String)>)]
    #   the tests that killed the mutant and every test that ran against it
    #   (kills included), each sorted and unique `[file, name]` pairs.
    def self.parse(buffer)
      killed = []
      ran = []
      buffer.dup.force_encoding(Encoding::UTF_8).each_line do |line|
        next unless line.end_with?("\n")

        event, file, name = parse_line(line)
        next unless file

        ran << [file, name]
        killed << [file, name] if event == KILL
      end
      [killed.uniq.sort, ran.uniq.sort]
    end

    # Parses one line into `[event, file, name]`, or nil when it is not one.
    #
    # @api private
    # @param line [String] one newline-terminated line.
    # @return [Array(String, String, String), nil]
    def self.parse_line(line)
      parsed = JSON.parse(line)
      return unless parsed.is_a?(Array) && parsed.size == 3 && parsed.all?(String)
      return unless [PASS, KILL].include?(parsed[0])

      parsed
    rescue JSON::ParserError
      nil
    end

    # A UTF-8 copy of `value`, with invalid bytes replaced, so JSON can encode it.
    #
    # @api private
    # @param value [Object] a file path or test name.
    # @return [String]
    def self.utf8(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end
    private_class_method :parse_line, :utf8
  end
end
