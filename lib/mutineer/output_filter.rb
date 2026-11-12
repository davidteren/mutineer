# frozen_string_literal: true

require_relative "redaction"

module Mutineer
  # Copies the process's stdout and stderr through {Redaction.text}. A fork
  # child and a subprocess inherit the pipe, so a line the app writes
  # straight to the inherited descriptor is redacted (#341). The copier runs
  # in this process. Children do not start their own: they only write.
  #
  # Stdlib only, so the app-side daemon can load this file. A line with no
  # password is copied unchanged, including its bytes.
  module OutputFilter
    # Seconds the copier waits for a last line after {uninstall} closes this
    # process's write end. A grandchild that still holds the pipe does not
    # extend the wait: the copier stops after this quiet poll. Same rule as
    # the daemon stderr drain (#341).
    QUIET_POLL = 0.05

    module_function

    # True while the descriptors point at the pipe.
    #
    # @return [Boolean]
    def installed?
      @installed == true
    end

    # Point each named stream at a pipe and start the copier. A second call
    # does nothing and returns false, so the caller that turned it on is the
    # one that turns it off. `streams` is `:stdout`, `:stderr`, or both.
    # Returns false without changing the descriptors when they cannot be
    # redirected (a closed stream).
    #
    # @param streams [Array<Symbol>]
    # @return [Boolean] true when this call started the copier.
    def install(streams: %i[stdout stderr])
      return false if installed?

      saved = {}
      stdio = {}
      readers = {}
      Array(streams).each do |name|
        io = stream_io(name)
        copy = io.dup
        copy.sync = true
        read, write = IO.pipe
        write.sync = true
        read.binmode
        read.close_on_exec = true
        io.reopen(write)
        io.sync = true
        write.close
        saved[name] = copy
        stdio[name] = io
        readers[read] = name
      end
      @saved = saved
      @stdio = stdio
      @readers = readers
      @installed = true
      @thread = Thread.new { drain } # rubocop:disable ThreadSafety/NewThread
      @thread.report_on_exception = false
      hook_exit
      true
    rescue StandardError
      restore(stdio || {}, saved || {})
      false
    end

    # Put the descriptors back and flush a trailing line that had no newline.
    # Does nothing when {install} is not on. Safe to call twice.
    #
    # @return [void]
    def uninstall
      return unless installed?

      @installed = false
      @stopping = true
      saved = @saved || {}
      stdio = @stdio || {}
      stdio.each do |name, io|
        copy = saved[name]
        io.reopen(copy) if copy && !copy.closed? && !io.closed?
      end
      @thread&.join(QUIET_POLL * 4)
      if @thread&.alive?
        @thread.kill
        @thread.join(QUIET_POLL * 4)
      end
      saved.each_value { |io| io.close unless io.closed? }
      (@readers || {}).each_key { |io| io.close unless io.closed? }
      @thread = nil
      @stopping = false
      @saved = {}
      @stdio = {}
      @readers = {}
    end

    # The real stream for `name`.
    #
    # @param name [Symbol] `:stdout` or `:stderr`.
    # @return [IO]
    def stream_io(name)
      name == :stdout ? STDOUT : STDERR
    end

    # Register the process-exit flush once. `exit!` skips it; callers that
    # use `exit!` call {uninstall} themselves.
    #
    # @return [void]
    def hook_exit
      return if @hooked

      @hooked = true
      at_exit { uninstall }
    end

    # Read both pipes until they close, or until {uninstall} asks the copier
    # to stop. One line is one redaction, so a password split across writes
    # is still hidden. A line with no newline is written when the pipe
    # closes or when the copier stops. A grandchild that keeps a write end
    # open does not hold the stop past {QUIET_POLL}.
    #
    # @return [void]
    def drain
      pending = Hash.new { |buffer, io| buffer[io] = +"".b }
      open = (@readers || {}).keys
      until open.empty?
        # A short wait, not a blocking select, so uninstall can stop the
        # copier while a grandchild still holds a write end.
        ready, = IO.select(open, nil, nil, QUIET_POLL)
        if ready.nil?
          break if @stopping

          next
        end

        ready.each do |io|
          chunk = io.read_nonblock(4096, exception: false)
          if chunk.nil?
            emit(@readers[io], pending[io]) unless pending[io].empty?
            pending[io].clear
            open.delete(io)
            io.close unless io.closed?
            next
          end
          next if chunk == :wait_readable

          buffer = pending[io]
          buffer << chunk.b
          while (cut = buffer.index("\n".b))
            emit(@readers[io], buffer.slice!(0..cut))
          end
        end
      end
      pending.each { |io, buffer| emit(@readers[io], buffer) unless buffer.empty? }
    rescue StandardError
      nil
    end

    # Write `line` to the original stream, redacted. The original bytes are
    # kept when redaction changes nothing, so a report with no password stays
    # byte for byte. An error writes {Redaction::FAILED}, never the raw line.
    #
    # @param stream [Symbol, nil]
    # @param line [String] raw bytes, with or without the trailing newline.
    # @return [void]
    def emit(stream, line)
      return if stream.nil?

      newline = line.end_with?("\n")
      raw = newline ? line.byteslice(0...-1) : line
      text = raw.dup.force_encoding(Encoding::UTF_8)
      clean = text.dup
      clean.scrub! unless clean.valid_encoding?
      redacted = Redaction.text(clean)
      payload = redacted == clean && clean == text ? raw : redacted.b
      write_out(stream, payload)
      write_out(stream, "\n".b) if newline
    rescue StandardError
      write_out(stream, Redaction::FAILED.b)
      write_out(stream, "\n".b) if newline
    end

    # Write to `$stdout` or `$stderr` when the caller replaced that variable
    # (a test capture). Otherwise write to the descriptor saved before
    # {install}, never back into the pipe.
    #
    # @param stream [Symbol]
    # @param data [String]
    # @return [void]
    def write_out(stream, data)
      current = stream == :stdout ? $stdout : $stderr
      pipe = @stdio[stream]
      target = current.equal?(pipe) ? @saved[stream] : current
      target&.write(data)
    rescue Errno::EPIPE, IOError
      nil
    end

    # Put any streams this failed {install} already moved back where they were.
    #
    # @param stdio [Hash{Symbol => IO}]
    # @param saved [Hash{Symbol => IO}]
    # @return [void]
    def restore(stdio, saved)
      stdio.each do |name, io|
        copy = saved[name]
        io.reopen(copy) if copy && !copy.closed? && !io.closed?
      end
      saved.each_value { |io| io.close unless io.closed? }
    rescue StandardError
      nil
    end
  end
end
