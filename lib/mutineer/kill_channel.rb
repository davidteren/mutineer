# frozen_string_literal: true

require "json"

module Mutineer
  # The line protocol a `--matrix` mutant child uses to tell its parent how its
  # tests went. One JSON array per line:
  #
  #   ["start", "serial" | "parallel"]   the recorder is armed; once, first
  #   ["pass", file, name, id]          a test passed against the mutant
  #   ["kill", file, name, id]          a test failed or errored: it killed it
  #   ["end"]                           the suite returned normally; once, last
  #
  # `id` tells two tests apart when `[file, name]` does not (an RSpec example
  # id such as `./spec/calc_spec.rb[1:2]`); for Minitest it equals the name. A
  # test line is written when the test is recorded, so a child killed at the
  # timeout has already sent every kill it saw. A skipped test sends nothing.
  # `parallel` means a test class runs its tests in parallel threads, where a
  # stop at the first failure cannot skip the tests already queued.
  #
  # A row is complete only with both `start` and `end` and no lost line: a test
  # that exits the process, a crash, or a recorder that never armed leaves one
  # out.
  #
  # Writing never raises: a recorder that broke the test run would change the
  # verdict, and the exit status decides the verdict. A lost line leaves the row
  # incomplete.
  #
  # Stdlib-only, so the app-side daemon can load the files that require it.
  module KillChannel
    # Event for a test that passed against the mutant.
    PASS = "pass"

    # Event for a test that failed or errored against the mutant: it killed it.
    KILL = "kill"

    # Event that opens a recorded run.
    START = "start"

    # Event that closes a run whose suite returned normally.
    FINISH = "end"

    # `start` mode of a run whose tests all run one after another.
    SERIAL = "serial"

    # `start` mode of a run where some test class runs its tests in parallel.
    PARALLEL = "parallel"

    # Serializes writes from tests that record on several threads.
    LOCK = Mutex.new

    # What one child sent. `killed` and `ran` are sorted, unique
    # `[file, name, id]` tests (`ran` includes the killers); `lost` counts lines
    # that could not be read, including a partial last line.
    Report = Struct.new(:killed, :ran, :started, :finished, :parallel, :lost, keyword_init: true)

    # Writes one test line.
    #
    # @param io [IO] the write end of the channel.
    # @param event [String] {PASS} or {KILL}.
    # @param file [String] the file that defines the test.
    # @param name [String] the test's display name, e.g. `CalculatorTest#test_add`.
    # @param id [String] what tells the test apart from others with its file and
    #   name; defaults to the name.
    # @return [void]
    def self.write(io, event, file, name, id = name)
      emit(io, [event, utf8(file), utf8(name), utf8(id)])
    end

    # Writes the `start` line.
    #
    # @param io [IO] the write end of the channel.
    # @param parallel [Boolean] some test class runs its tests in parallel.
    # @return [void]
    def self.write_start(io, parallel:)
      emit(io, [START, parallel ? PARALLEL : SERIAL])
    end

    # Writes the `end` line.
    #
    # @param io [IO] the write end of the channel.
    # @return [void]
    def self.write_end(io)
      emit(io, [FINISH])
    end

    # Reads every complete line of `buffer`.
    #
    # @param buffer [String] bytes read from the channel.
    # @return [Report]
    def self.parse(buffer)
      report = Report.new(killed: [], ran: [], started: false, finished: false, parallel: false, lost: 0)
      buffer.dup.force_encoding(Encoding::UTF_8).each_line do |line|
        fields = line.end_with?("\n") ? parse_line(line) : nil
        fields ? apply(report, fields) : report.lost += 1
      end
      report.killed = report.killed.uniq.sort
      report.ran = report.ran.uniq.sort
      report
    end

    # Adds one parsed line to `report`.
    #
    # @api private
    # @param report [Report] the report being built.
    # @param fields [Array<String>] a valid line's fields.
    # @return [void]
    def self.apply(report, fields)
      case fields[0]
      when START
        report.started = true
        report.parallel = fields[1] == PARALLEL
      when FINISH then report.finished = true
      else
        test = fields[1, 3]
        report.ran << test
        report.killed << test if fields[0] == KILL
      end
    end

    # Parses one line into its fields, or nil when it is not a valid line.
    #
    # @api private
    # @param line [String] one newline-terminated line.
    # @return [Array<String>, nil]
    def self.parse_line(line)
      fields = JSON.parse(line)
      return unless fields.is_a?(Array) && fields.all?(String)

      valid =
        case fields[0]
        when PASS, KILL then fields.size == 4
        when START then fields.size == 2 && [SERIAL, PARALLEL].include?(fields[1])
        when FINISH then fields.size == 1
        end
      fields if valid
    rescue JSON::ParserError
      nil
    end

    # Writes one line. Never raises.
    #
    # @api private
    # @param io [IO] the write end of the channel.
    # @param fields [Array<String>] the line's fields.
    # @return [void]
    def self.emit(io, fields)
      line = "#{JSON.generate(fields)}\n"
      LOCK.synchronize { io.write(line) }
    rescue StandardError
      nil
    end

    # A UTF-8 copy of `value`, with invalid bytes replaced, so JSON can encode it.
    #
    # @api private
    # @param value [Object] a file path or test name.
    # @return [String]
    def self.utf8(value)
      str = value.to_s
      str = str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless str.encoding == Encoding::UTF_8
      str.scrub
    end
    private_class_method :apply, :parse_line, :emit, :utf8
  end
end
