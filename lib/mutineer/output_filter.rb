# frozen_string_literal: true

require_relative "redaction"

module Mutineer
  # Copies the process's stdout and stderr through {Redaction.text}. A fork
  # child and a subprocess inherit the pipe. The child starts its own copier
  # so a DATABASE_URL it sets is hidden (#341). Before a fork child execs, its
  # copier stops, so the program writes to the parent's pipe and the parent
  # redacts it with the parent's environment. A program that would run with
  # a DATABASE_URL the parent does not know writes to the null device.
  #
  # Stdlib only, so the app-side daemon can load this file. A chunk with no
  # password is copied unchanged, including its bytes.
  module OutputFilter
    # Seconds to wait for a last buffered chunk after {uninstall} closes this
    # process's write end. A grandchild that still holds the pipe does not
    # extend the wait. Bytes already read are written before the copier
    # returns; a slow reader blocks that write, and the bytes are not dropped.
    QUIET_POLL = 0.05

    # Runs {after_fork!} in the child. Kernel#fork, Kernel.fork, and
    # Process.fork are separate, so all three are wrapped.
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

    # Stops a fork child's copier before exec. The copier thread and its read
    # end do not survive exec, so the program would write to a pipe nobody
    # reads. Kernel#exec, Kernel.exec, and Process.exec are separate, so all
    # three are wrapped.
    module ExecHook
      # @return [void] does not return when exec succeeds.
      def exec(*args)
        OutputFilter.before_exec(args)
        super
      end
    end

    # Drops a spawned program's output when its env hash sets a DATABASE_URL
    # this process's copier does not know. A URL set in ENV first is known:
    # the copier reads ENV. Process has no `system`, so it gets {SpawnHook}
    # only.
    module SpawnHook
      # @return [Integer] the child pid.
      def spawn(*args)
        super(*OutputFilter.spawn_args(args))
      end
    end

    # The `system` form of {SpawnHook}, for Kernel#system and Kernel.system.
    module SystemHook
      # @return [Boolean, nil] as Kernel#system.
      def system(*args)
        super(*OutputFilter.spawn_args(args))
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
      @fork_child = true
      # The parent's copier redacts with this URL, read before child code runs.
      @parent_url = ENV["DATABASE_URL"].to_s
      @installed = false
      @thread = nil
      @stopping = false
      @hooked = false
      @readers = {}
      @saved = {}
      @stdio = {}
      reads.each { |io| io.close unless io.closed? }
      silence_stdio unless install(streams: names || [:stderr]) == :started
    rescue StandardError
      silence_stdio
    end

    # In a fork child, put the parent's pipe back on stdout and stderr and
    # flush this copier. Does nothing in the process that started the filter:
    # its saved descriptors are the real terminal, which is not redacted.
    # When the program would run with a DATABASE_URL the parent does not
    # know, its output goes to the null device instead: the parent could not
    # hide that password.
    #
    # @param args [Array] the arguments given to exec; a leading Hash is its
    #   environment.
    # @return [void]
    def before_exec(args = [])
      return unless @fork_child

      known = known_url?(args, @parent_url)
      uninstall
      silence_stdio unless known
    end

    # `args` for spawn or system, with stdout and stderr sent to the null
    # device when the program's env hash sets a DATABASE_URL this process
    # does not know. The caller's own redirects of stdout and stderr are
    # dropped too: a target such as `err: :out` or `err: STDOUT` would still
    # reach this pipe, and Ruby refuses a stream given twice.
    #
    # @param args [Array] the arguments given to spawn or system.
    # @return [Array]
    def spawn_args(args)
      return args if !installed? || known_url?(args, ENV.fetch("DATABASE_URL", nil))

      options = args.size > 1 && args.last.is_a?(Hash) ? args.last : {}
      kept = options.reject { |key, _| Array(key).intersect?([:out, :err, 1, 2, STDOUT, STDERR]) }
      command = options.empty? ? args : args[0...-1]
      command + [kept.merge(out: File::NULL, err: File::NULL)]
    end

    # True when the program `args` start would run with no DATABASE_URL,
    # with `current`, or with a dotenv URL redaction already knows. The env
    # hash wins; ENV counts only when `unsetenv_others` does not clear it.
    #
    # @param args [Array] exec, spawn, or system arguments.
    # @param current [String, nil] the URL the redacting copier knows.
    # @return [Boolean]
    def known_url?(args, current)
      env = args.first.is_a?(Hash) ? args.first : {}
      options = args.size > 1 && args.last.is_a?(Hash) ? args.last : {}
      inherited = options[:unsetenv_others] ? nil : ENV.fetch("DATABASE_URL", nil)
      url = (env.key?("DATABASE_URL") ? env["DATABASE_URL"] : inherited).to_s
      url.empty? || url == current.to_s || Redaction.extra_urls.include?(url)
    end

    # Point stdout and stderr at the null device. Used when this fork cannot
    # start its own copier: the parent's pipe would otherwise publish a
    # password this process set and the parent does not know.
    #
    # @return [void]
    def silence_stdio
      File.open(File::NULL, "w") do |null|
        STDOUT.reopen(null) unless STDOUT.closed?
        STDERR.reopen(null) unless STDERR.closed?
      end
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

    # Wrap fork, exec, spawn, and system once per process.
    #
    # @return [void]
    def hook_fork
      return if @fork_hooked

      @fork_hooked = true
      [Kernel, Kernel.singleton_class, Process.singleton_class].each do |target|
        target.prepend(ForkHook)
        target.prepend(ExecHook)
        target.prepend(SpawnHook)
      end
      Kernel.prepend(SystemHook)
      Kernel.singleton_class.prepend(SystemHook)
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
          # Nothing new can be emitted before a newline, so a long line is not
          # rescanned on every read.
          flush_pending(io, pending, flush: false) if chunk.include?("\n")
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
