# frozen_string_literal: true

module Mutineer
  # Writes each failing Minitest result to an IO, in the numbered
  # `N) Failure:` / `N) Error:` form of Minitest's summary: the test name and
  # place, the message, and for an error its backtrace. The clean check reads
  # it to name the failing test (#360).
  #
  # It is not a `Minitest::SummaryReporter`. Rails' Minitest plugin removes
  # every reporter of that class, so a summary-based report came back empty
  # under `--rails` (#497). It needs no Minitest at load, so the clean-check
  # child scripts can require it by {PATH}.
  #
  # @api private
  class MinitestFailureReport
    # Absolute path of this file, for the child scripts to require.
    PATH = File.expand_path(__FILE__)

    # @return [IO] where {#report} writes.
    attr_reader :io

    # @param io [IO] where {#report} writes.
    def initialize(io)
      @io = io
      @failures = []
    end

    # Minitest reporter hook. Does nothing.
    #
    # @return [void]
    def start; end

    # Minitest reporter hook. Does nothing.
    #
    # @param _klass [Class] the test class.
    # @param _name [String] the test name.
    # @return [void]
    def prerecord(_klass, _name); end

    # Keeps a failed or errored result.
    #
    # @param result [Minitest::Result] one test's result.
    # @return [void]
    def record(result)
      @failures << result unless result.passed? || result.skipped?
    end

    # Writes the kept results, numbered from 1.
    #
    # @return [void]
    def report
      @failures.each_with_index { |result, i| io.puts format("\n%3d) %s", i + 1, result) }
    end

    # False once a test failed or errored. A plugin can drop the summary
    # reporters that decide the run's result, so this one fails closed too.
    #
    # @return [Boolean]
    def passed?
      @failures.empty?
    end
  end
end
