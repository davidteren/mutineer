# frozen_string_literal: true

require "json"

module Mutineer
  # The line protocol a `--matrix` mutant child uses to tell its parent how its
  # tests went. One JSON array per line:
  #
  #   ["start"]                         the recorder is armed; once, first
  #   ["pass", file, name, id]          a test passed against the mutant
  #   ["kill", file, name, id]          a test failed or errored: it killed it
  #   ["parallel"]                      the run reached its parallel tests; once
  #   ["cleanup"]                       every test ran; suite hooks follow; once
  #   ["lost"]                          a test the recorder could not describe
  #   ["end"]                           the suite returned with every test seen;
  #                                     once, last
  #
  # `id` tells two tests apart when `[file, name]` does not, and it is what
  # identifies the test across mutants (an RSpec example id such as
  # `./spec/calc_spec.rb[1:2]`; the name can change with the mutant). For
  # Minitest it equals the name. A test line is written when the test is
  # recorded, so a child killed at the timeout has already sent every kill it
  # saw. A skipped test sends nothing.
  #
  # Minitest runs its serial test classes first and its `parallelize_me!`
  # classes after them, and the stop at the first failure of a run without
  # `--matrix` skips everything after a serial kill. `parallel` marks where the
  # parallel tests begin, so the parent can tell a kill that the stop would have
  # followed from one it could not. `cleanup` marks where the tests end and the
  # suite's own hooks begin (RSpec `after(:suite)`), which a run without
  # `--matrix` runs after a failure as well.
  #
  # A row is complete only with `start` and `end`, in order, and no lost line: a
  # test that exits the process, a crash, an interrupted run or a recorder that
  # never armed leaves one out. A stream out of order (a duplicate marker, a
  # test line before `start` or after `end`) is invalid, and the parent trusts
  # nothing from it.
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

    # Event that marks the first parallel test of a run.
    PARALLEL = "parallel"

    # Event that marks the end of the tests and the start of the suite's cleanup.
    CLEANUP = "cleanup"

    # Event for a test the recorder could not describe.
    LOST = "lost"

    # Event that closes a run whose suite returned with every test seen.
    FINISH = "end"

    # Serializes writes from tests that record on several threads.
    LOCK = Mutex.new

    # What one child sent. `killed` and `ran` are sorted, unique
    # `[file, name, id]` tests (`ran` includes the killers); `lost` counts lines
    # that could not be read, including a partial last line. `parallel` and
    # `cleanup` say the marker arrived, and `serial_kill` that a test killed
    # before the `parallel` marker. `invalid` is set by any line out of order.
    Report = Struct.new(:killed, :ran, :started, :finished, :parallel, :cleanup, :serial_kill, :invalid, :lost,
                        keyword_init: true)

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
    # @return [void]
    def self.write_start(io)
      emit(io, [START])
    end

    # Writes the `parallel` line.
    #
    # @param io [IO] the write end of the channel.
    # @return [void]
    def self.write_parallel(io)
      emit(io, [PARALLEL])
    end

    # Writes the `cleanup` line.
    #
    # @param io [IO] the write end of the channel.
    # @return [void]
    def self.write_cleanup(io)
      emit(io, [CLEANUP])
    end

    # Writes the `lost` line, for a test the recorder could not describe.
    #
    # @param io [IO] the write end of the channel.
    # @return [void]
    def self.write_lost(io)
      emit(io, [LOST])
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
      report = Report.new(killed: [], ran: [], started: false, finished: false, parallel: false, cleanup: false,
                          serial_kill: false, invalid: false, lost: 0)
      buffer.dup.force_encoding(Encoding::UTF_8).each_line do |line|
        fields = line.end_with?("\n") ? parse_line(line) : nil
        fields ? apply(report, fields) : report.lost += 1
      end
      report.killed = report.killed.uniq.sort
      report.ran = report.ran.uniq.sort
      report
    end

    # Adds one parsed line to `report`. A line out of order marks the report
    # invalid; the line still counts, since what it names happened.
    #
    # @api private
    # @param report [Report] the report being built.
    # @param fields [Array<String>] a valid line's fields.
    # @return [void]
    def self.apply(report, fields)
      case fields[0]
      when START
        report.invalid = true if report.started || report.ran.any? || report.parallel || report.cleanup || report.finished
        report.started = true
      when PARALLEL
        report.invalid = true unless open?(report) && !report.parallel
        report.parallel = true
      when CLEANUP
        report.invalid = true unless open?(report) && !report.cleanup
        report.cleanup = true
      when LOST then report.lost += 1
      when FINISH
        report.invalid = true unless open?(report) && !report.finished
        report.finished = true
      else
        report.invalid = true unless open?(report) && !report.cleanup
        test = fields[1, 3]
        report.ran << test
        return unless fields[0] == KILL

        report.killed << test
        report.serial_kill = true unless report.parallel
      end
    end

    # True between `start` and `end`.
    #
    # @api private
    # @param report [Report] the report being built.
    # @return [Boolean]
    def self.open?(report)
      report.started && !report.finished
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
        when START, PARALLEL, CLEANUP, LOST, FINISH then fields.size == 1
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
    private_class_method :apply, :open?, :parse_line, :emit, :utf8
  end
end
