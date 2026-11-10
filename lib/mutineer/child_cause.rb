# frozen_string_literal: true

require_relative "redaction"

module Mutineer
  # Carries one line from a mutant's child to its parent: why the child
  # raised. The parent puts it in the errored mutant's `details`, so the JSON
  # report names the cause, not only stderr (#388).
  #
  # The child writes the line to a pipe just before `exit!`; the parent reads
  # it after the reap, without blocking, so a grandchild that still holds the
  # write end cannot delay the result.
  #
  # Stdlib only: the app-side daemon loads this file without the rest of
  # mutineer.
  module ChildCause
    # The longest line sent, in characters, including the `...` of a cut line.
    LIMIT = 500

    module_function

    # The error as `Class: first non-blank message line`, or the class alone
    # when the message is blank or is the class name. Redacted before the cut,
    # so a cut cannot leave part of a password. Never raises.
    #
    # @param error [Exception]
    # @return [String]
    def line(error)
      name = Redaction.text(error.class)
      first = Redaction.text(error.message).lines.map(&:strip).find { |l| !l.empty? }
      text = first.nil? || first == name ? name : "#{name}: #{first}"
      text.length > LIMIT ? "#{text[0, LIMIT - 3]}..." : text
    rescue StandardError
      Redaction::FAILED
    end

    # Write {line} for `error` to the pipe, but only from the mutant's child
    # itself. A grandchild made with a bare `fork` (no block) runs the child's
    # code after the fork, so its error can reach the same rescue; it writes
    # nothing, so `details` never names another process's error. Never
    # raises: a failed write only loses the cause, never the verdict.
    #
    # @param io [IO] the pipe's write end, with `sync` on (the child ends with `exit!`).
    # @param error [Exception]
    # @param owner [Integer] the pid of the mutant's child.
    # @return [void]
    def write(io, error, owner)
      return unless Process.pid == owner

      io.write("#{line(error)}\n")
    rescue StandardError
      nil
    end

    # The last complete line in the pipe now, as UTF-8, or nil. Reads without
    # blocking.
    #
    # @param io [IO] the pipe's read end.
    # @return [String, nil]
    def read(io)
      buffer = +""
      loop do
        chunk = io.read_nonblock(65_536, exception: false)
        break if chunk.nil? || chunk == :wait_readable

        buffer << chunk
      end
      last = buffer.lines.reverse.find { |l| l.end_with?("\n") }
      last && Redaction.utf8(last.chomp.force_encoding(Encoding::UTF_8))
    rescue StandardError
      nil
    end
  end
end
