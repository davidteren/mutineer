# frozen_string_literal: true

require_relative "redaction"

module Mutineer
  # Carries one line from a mutant's child to its parent: why the child
  # raised. The parent puts it in the errored mutant's `details`, so the JSON
  # report names the cause, not only stderr (#388, #417).
  #
  # The child writes the line to a pipe just before `exit!`; the parent reads
  # it after the reap, without blocking, so a grandchild that still holds the
  # write end cannot delay the result.
  #
  # The fork boundary {arm!}s the write end as process-local state so Minitest
  # and RSpec can write a cause without a new runner argument (plan KTD3).
  #
  # Stdlib only: the app-side daemon loads this file without the rest of
  # mutineer.
  module ChildCause
    # The longest line sent, in characters, including the `...` of a cut line.
    LIMIT = 500

    # Fixed text when `--matrix` ends early after a serial database error (KTD5).
    MATRIX_EARLY_END =
      "a test failed with a database error, then the child ended before the suite finished"

    # Fixed text when RSpec reports an error outside examples (KTD5).
    RSPEC_OUTSIDE_EXAMPLES =
      "RSpec reported an error outside its examples, for example a spec file that raised while it loaded"

    module_function

    # Remembers the cause pipe for this process so suite code can write without
    # holding the IO. Only {#write} / {#write_text} from the same pid succeed.
    #
    # @param io [IO] the pipe's write end, with `sync` on.
    # @param owner [Integer] the pid of the mutant's child.
    # @return [void]
    def arm!(io, owner)
      @armed_io = io
      @armed_owner = owner
    end

    # Clears {arm!}. Safe when nothing was armed.
    #
    # @return [void]
    def disarm!
      @armed_io = nil
      @armed_owner = nil
    end

    # The error as `Class: first non-blank message line`, or the class alone
    # when the message is blank or is the class name. Redacted before the cut,
    # so a cut cannot leave part of a password. Never raises.
    #
    # @param error [Exception]
    # @return [String]
    def line(error)
      name = Redaction.text(error.class)
      first = nil
      Redaction.text(error.message).each_line("\n") do |l|
        first = l.strip
        break unless first.empty?
      end
      first = nil if first&.empty?
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

      write_to(io, line(error))
    end

    # Write {line} for `error` to the armed pipe (#417).
    #
    # @param error [Exception]
    # @return [void]
    def write_error(error)
      return unless armed_here?

      write_to(@armed_io, line(error))
    end

    # Write a fixed or already-built cause text to the armed pipe (#417).
    # Redacted and cut like {line}.
    #
    # @param text [String]
    # @return [void]
    def write_text(text)
      return unless armed_here?

      body = Redaction.text(text.to_s)
      body = body.length > LIMIT ? "#{body[0, LIMIT - 3]}..." : body
      write_to(@armed_io, body)
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
      last = buffer.lines("\n").reverse.find { |l| l.end_with?("\n") }
      last && Redaction.utf8(last.chomp("\n").force_encoding(Encoding::UTF_8))
    rescue StandardError
      nil
    end

    # @api private
    # @return [Boolean]
    def armed_here?
      @armed_io && @armed_owner && Process.pid == @armed_owner
    end

    # @api private
    # @param io [IO]
    # @param text [String]
    # @return [void]
    def write_to(io, text)
      io.write("#{text}\n")
    rescue StandardError
      nil
    end
    private_class_method :write_to
  end
end
