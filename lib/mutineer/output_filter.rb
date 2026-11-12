# frozen_string_literal: true

require_relative "redaction"

module Mutineer
  # Copies the process's stdout and stderr through {Redaction.text}. A fork
  # child and a subprocess inherit the pipe. The child starts its own copier
  # so a DATABASE_URL it sets is hidden (#341). A program it execs still
  # writes to the pipe, and this process redacts with its own environment.
  #
  # Stdlib only, so the app-side daemon can load this file. A chunk with no
  # password is copied unchanged, including its bytes.
  module OutputFilter
    # Seconds to wait for a last buffered chunk after {uninstall} closes this
    # process's write end. A grandchild that still holds the pipe does not
    # extend the wait. Bytes already read are written before the copier
    # returns; a slow reader blocks that write, and the bytes are not dropped.
    QUIET_POLL = 0.05

    # Runs {after_fork!} in the child. Kernel#fork and Process.fork are
    # separate, so both are wrapped.
    module ForkHook
      # @return [Integer, nil] the child pid in the parent; nil in the child
      #   when no block is given.
      def fork(*)
        if block_given?
          super do
            OutputFilter.after_fork!
            yield
          end
        else
          pid = super
          OutputFilter.after_fork! if pid.nil?
          pid
        end
      end
    end

    # Flushes the copier before exit!. exit! skips at_exit, and a forked
    # test exits that way.
    module ExitHook
      # @param status [Boolean, Integer]
      # @return [void]
      def exit!(status = true)
        OutputFilter.uninstall
        super
      end
    end

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
    # Returns :failed without leaving the descriptors redirected when they
    # cannot be moved (a closed stream). Returns :already when a copier is
    # already running, so the caller that started it stays the one that
    # stops it.
    #
    # @param streams [Array<Symbol>]
    # @return [Symbol] :started, :already, or :failed.
    def install(streams: %i[stdout stderr])
      return :already if installed?

      names = Array(streams)
      saved = {}
      stdio = {}
      readers = {}
      names.each do |name|
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
      @streams = names
      @saved = saved
      @stdio = stdio
      @readers = readers
      @stopping = false
      @installed = true
      hook_fork
      hook_exit!
      @thread = Thread.new { drain } # rubocop:disable ThreadSafety/NewThread
      @thread.report_on_exception = false
      hook_exit
      :started
    rescue StandardError
      restore(stdio || {}, saved || {})
      readers&.each_key { |io| io.close unless io.closed? }
      :failed
    end

    # Put the descriptors back and write every byte already queued. Does
    # nothing when {install} is not on. Safe to call twice. Does not kill the
    # copier: a slow stdout must still receive the report. A grandchild that
    # holds the pipe does not add a wait past {QUIET_POLL}, because the
    # copier stops reading once the pipe is empty.
    #
    # @return [void]
    def uninstall
      return unless installed?

      @stopping = true
      saved = @saved || {}
      stdio = @stdio || {}
      stdio.each do |name, io|
        copy = saved[name]
        io.reopen(copy) if copy && !copy.closed? && !io.closed?
      end
      @thread&.join
      saved.each_value { |io| io.close unless io.closed? }
      (@readers || {}).each_key { |io| io.close unless io.closed? }
      @installed = false
      @thread = nil
      @stopping = false
      @saved = {}
      @stdio = {}
      @readers = {}
    end

    # Start a copier in a fork child. The parent's thread was not copied.
    # This process redacts with its own environment, then writes to the
    # parent's pipe. The parent's read ends are closed so this process does
    # not steal the parent's bytes.
    #
    # @return [void]
    def after_fork!
      return unless installed?

      names = @streams
      reads = (@readers || {}).keys.dup
      @installed = false
      @thread = nil
      @stopping = false
      @hooked = false
      @readers = {}
      @saved = {}
      @stdio = {}
      reads.each { |io| io.close unless io.closed? }
      install(streams: names || [:stderr])
    rescue StandardError
      nil
    end

    # The real stream for `name`.
    #
    # @param name [Symbol] `:stdout` or `:stderr`.
    # @return [IO]
    def stream_io(name)
      name == :stdout ? STDOUT : STDERR
    end

    # Register the process-exit flush once. `exit!` skips at_exit; {ExitHook}
    # covers that.
    #
    # @return [void]
    def hook_exit
      return if @hooked

      @hooked = true
      at_exit { uninstall }
    end

    # Wrap fork and exit! once per process.
    #
    # @return [void]
    def hook_fork
      return if @fork_hooked

      @fork_hooked = true
      Kernel.prepend(ForkHook)
      Process.singleton_class.prepend(ForkHook)
    end

    # @return [void]
    def hook_exit!
      return if @exit_hooked

      @exit_hooked = true
      Kernel.prepend(ExitHook)
    end

    # Read both pipes until they close, or until {uninstall} has closed this
    # process's write ends and the pipes are empty. A password that contains
    # a newline stays in the buffer until the whole form has arrived.
    #
    # @return [void]
    def drain
      pending = Hash.new { |buffer, io| buffer[io] = +"".b }
      open = (@readers || {}).keys
      until open.empty?
        if @stopping
          drain_ready(open, pending)
          break
        end
        ready, = IO.select(open, nil, nil, QUIET_POLL)
        next unless ready

        ready.each do |io|
          chunk = io.read_nonblock(4096, exception: false)
          if chunk.nil?
            flush_pending(io, pending, flush: true)
            open.delete(io)
            io.close unless io.closed?
            next
          end
          next if chunk == :wait_readable

          pending[io] << chunk.b
          flush_pending(io, pending, flush: false)
        end
      end
      open.each { |io| flush_pending(io, pending, flush: true) }
    rescue StandardError
      nil
    end

    # Read what is already buffered, plus one quiet poll, then stop. Used
    # after {uninstall} closes this process's write ends.
    #
    # @param open [Array<IO>]
    # @param pending [Hash{IO => String}]
    # @return [void]
    def drain_ready(open, pending)
      open.each do |io|
        loop do
          chunk = io.read_nonblock(4096, exception: false)
          if chunk == :wait_readable
            break unless io.wait_readable(QUIET_POLL)

            next
          end
          break if chunk.nil?

          pending[io] << chunk.b
        end
        flush_pending(io, pending, flush: true)
      end
    end

    # Redact and write the part of `pending[io]` that is safe to emit.
    #
    # @param io [IO]
    # @param pending [Hash{IO => String}]
    # @param flush [Boolean]
    # @return [void]
    def flush_pending(io, pending, flush:)
      ready, pending[io] = Redaction.take_redactable(pending[io], flush: flush)
      emit(@readers[io], ready)
    end

    # Write `chunk` to the original stream, redacted. The original bytes are
    # kept when redaction changes nothing, so a report with no password stays
    # byte for byte. An error writes {Redaction::FAILED}, never the raw chunk.
    #
    # @param stream [Symbol, nil]
    # @param chunk [String] raw bytes. May contain newlines.
    # @return [void]
    def emit(stream, chunk)
      return if stream.nil? || chunk.nil? || chunk.empty?

      text = chunk.dup.force_encoding(Encoding::UTF_8)
      clean = text.dup
      clean.scrub! unless clean.valid_encoding?
      redacted = Redaction.text(clean)
      # Unchanged text keeps the original bytes, including invalid ones.
      # A replaced secret is the redacted UTF-8 string.
      payload = redacted == clean ? chunk : redacted.b
      write_out(stream, payload)
    rescue StandardError
      write_out(stream, Redaction::FAILED.b)
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
