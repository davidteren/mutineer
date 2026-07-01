# frozen_string_literal: true

require "json"
require "tempfile"

module Mutineer
  # #26/#27 Phase 2a — the app-side daemon (persistent worker).
  #
  # Runs UNDER THE APP'S OWN BUNDLE/RUBY (the tool's DaemonClient spawns it via
  # `bundle exec ruby`). It boots the app ONCE, then serves per-mutant test-run
  # requests over stdin/stdout as newline-delimited JSON. For each request it FORKS
  # a child that loads the mutated source text the tool sent, runs the covering
  # tests, and exits with a status the parent decodes into a verdict.
  #
  # HARD CONSTRAINT (KTD-2/R4): this file must be loadable WITHOUT Prism or the rest
  # of mutineer — the app's Ruby may be < 3.4 (no stdlib Prism) and its bundle has no
  # mutineer. So it requires ONLY stdlib + the app's own boot file; it re-implements
  # the fork/timeout/decode loop rather than requiring `isolation.rb` (which pulls in
  # Prism). All parsing/mutation happened tool-side; the daemon only `load`s text.
  #
  # Protocol (one JSON object per line, both directions):
  #   boot in  : {"cmd":"boot","project_root":"...","boot":"config/environment",
  #               "load_paths":["test"],"framework":"minitest","rails":true}
  #   ready out: {"ready":true,"ruby":"3.3.6"}   (or {"ready":false,"error":"..."} then exit)
  #   run  in  : {"id":N,"payload":{"code":"<ruby>","source_file":"app/models/order.rb"},
  #               "tests":["test/models/order_test.rb"],"timeout":30}
  #   verdict  : {"id":N,"verdict":"survived"|"killed"|"error"|"timeout"}
  #   quit in  : {"cmd":"quit"}
  #
  # Verdict mapping (KTD-5, Phase-2a honest limit): child exit 0=survived (suite
  # passed), 1=killed (suite failed), 2=error (child raised AROUND the test — load or
  # boot failure); parent-detected timeout. Tagging an in-TEST DB error as `error`
  # (vs killed) is a Phase-2b concern (needs the after_fork adapter's re-raise).
  module DaemonServer
    POLL = 0.02

    class << self
      # Serve the protocol on the given IO pair (defaults to stdio). Returns on quit.
      #
      # @param input [IO] request stream.
      # @param output [IO] verdict stream.
      # @param errio [IO] diagnostics stream (never the IPC channel).
      # @return [void]
      def run(input: $stdin, output: $stdout, errio: $stderr)
        @errio = errio
        @output = output
        boot_line = input.gets
        return if boot_line.nil? # client vanished before boot

        boot!(JSON.parse(boot_line.strip))
        output.puts(JSON.generate("ready" => true, "ruby" => RUBY_VERSION))
        output.flush

        input.each_line do |line|
          line = line.strip
          next if line.empty?

          begin
            req = JSON.parse(line)
          rescue JSON::ParserError => e
            # A corrupt request line must not crash the daemon — reply and read on.
            output.puts(JSON.generate("verdict" => "error", "detail" => "protocol: #{e.message}"))
            output.flush
            next
          end
          break if req["cmd"] == "quit"

          output.puts(JSON.generate(run_mutant(req)))
          output.flush
        end
      end

      private

      # BOOT ONCE. chdir + require the app's boot file so the whole app is loaded and
      # inherited by every fork. Never requires mutineer.
      def boot!(cfg)
        @framework = cfg.fetch("framework", "minitest")
        Dir.chdir(cfg["project_root"]) if cfg["project_root"]
        ENV["RAILS_ENV"] ||= "test" if cfg["rails"]
        Array(cfg["load_paths"]).each { |d| $LOAD_PATH.unshift(File.expand_path(d)) }
        require File.expand_path(cfg["boot"]) if cfg["boot"]
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Boot failed (bad boot path, app error) — tell the client and exit so it can
        # surface a clean error rather than hang on the handshake.
        @output.puts(JSON.generate("ready" => false, "error" => "#{e.class}: #{e.message}"))
        @output.flush
        exit!(1)
      end

      # Fork a child to run one mutant in isolation; decode its exit into a verdict.
      def run_mutant(req)
        timeout = req.fetch("timeout", 30)
        pid = fork do
          # New process group so a per-fork timeout can SIGKILL the whole subtree
          # (carries the Phase-1 pgroup discipline), and silence the child's stdout so
          # test-framework output can never corrupt the IPC pipe (KTD-6).
          Process.setpgid(0, 0) rescue nil # rubocop:disable Style/RescueModifier
          $stdout.reopen(File::NULL, "w")
          code =
            begin
              apply_payload(req["payload"])
              run_tests(Array(req["tests"]))
            rescue Exception => e # rubocop:disable Lint/RescueException
              @errio.puts("[daemon-child] #{e.class}: #{e.message}")
              2
            end
          exit!(code)
        end
        { "id" => req["id"], "verdict" => wait_verdict(pid, timeout) }
      end

      # Single-waiter deadline loop (mirrors Isolation/ExternalBackend, re-implemented
      # here because Isolation pulls in Prism). SIGKILL the child's process group past
      # the deadline; a signalled/crashed child (nil exitstatus) is `error`.
      def wait_verdict(pid, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          reaped, status = Process.waitpid2(pid, Process::WNOHANG)
          if reaped
            return { 0 => "survived", 1 => "killed" }.fetch(status.exitstatus, "error")
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            begin
              Process.kill(:KILL, -pid)
            rescue Errno::ESRCH, Errno::EPERM
              Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
            end
            Process.waitpid(pid) rescue nil # rubocop:disable Style/RescueModifier
            return "timeout"
          end
          sleep POLL
        end
      end

      # Write the tool-built mutated text to a tempfile and `load` it — reopening the
      # mutated class/method in THIS child only. The file goes in the system tmpdir,
      # NOT beside the real source: an app dir is Zeitwerk-autoloaded, and a stray
      # `.rb` there (or an orphan left by a SIGKILLed timeout child) makes Rails choke
      # on the tempfile's constant name. Rails models are autoloaded (no
      # `require_relative` to resolve against neighbours), so the tmpdir is safe. Same
      # code path for reload (whole file) and redefine (wrapped snippet) — both are
      # ready-to-load Ruby the tool produced.
      def apply_payload(payload)
        Tempfile.create(["mutineer_daemon", ".rb"]) do |f|
          f.write(payload.fetch("code"))
          f.flush
          load f.path
        end
      end

      # Load the covering test files and run them; 0 = all passed (survived),
      # 1 = a failure/error (killed). Minitest only in 2a (rspec is a later unit).
      def run_tests(tests)
        raise "unsupported framework #{@framework.inspect}" unless @framework == "minitest"

        require "minitest"
        require "rails/test_help" if defined?(Rails)
        tests.each { |t| load File.expand_path(t) }
        Minitest.run([]) ? 0 : 1
      end
    end
  end
end
