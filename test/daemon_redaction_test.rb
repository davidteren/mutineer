# frozen_string_literal: true

require "minitest/mock"
require "open3"
require "rbconfig"
require "stringio"
require "tempfile"
require_relative "test_helper"
require "mutineer/daemon_server"
require "mutineer/coverage_map"
require "mutineer/daemon_client"

# Rails parses DATABASE_URL itself, so a malformed one raises a URI error that
# quotes the whole URL. No daemon reply or stderr line may echo the password.
class DaemonRedactionTest < Minitest::Test
  # A malformed URL (space in the host), as Rails would reject it.
  BAD_URL = "postgres://u:s3cret@ho st/db"
  # A stand-in for the RailsWorkerDb adapter that fails with a credentialed URL.
  class LeakyWorkerDb
    # @raise [RuntimeError]
    def self.provision(_slots) = raise("could not reach #{BAD_URL}")

    # @raise [RuntimeError]
    def self.after_fork(*, **) = raise("routing failed for #{BAD_URL}")
  end

  def setup
    @saved_url = ENV.fetch("DATABASE_URL", nil)
    ENV["DATABASE_URL"] = BAD_URL
  end

  def teardown
    ENV["DATABASE_URL"] = @saved_url
    %i[@worker_db @errio @cfg @slot_ready @source_dirs].each do |ivar|
      Mutineer::DaemonServer.instance_variable_set(ivar, nil)
    end
  end

  def test_boot_reply_hides_the_password_from_a_rails_style_uri_error
    Dir.mktmpdir do |dir|
      boot = File.join(dir, "boot.rb")
      File.write(boot, "require \"uri\"\nURI.parse(ENV.fetch(\"DATABASE_URL\"))\n")
      lib = File.expand_path("../lib", __dir__)
      script = "require \"mutineer/daemon_server\"; Mutineer::DaemonServer.run"
      stdin = JSON.generate("cmd" => "boot", "project_root" => dir, "boot" => boot)
      out, err, = Open3.capture3({ "DATABASE_URL" => BAD_URL }, RbConfig.ruby, "-I", lib, "-e", script,
                                 stdin_data: "#{stdin}\n")
      reply = JSON.parse(out.lines.last)

      refute reply["ready"]
      assert_includes reply["error"], "URI::InvalidURIError"
      assert_includes reply["error"], "[REDACTED]"
      refute_includes out + err, "s3cret"
    end
  end

  def test_provision_reply_hides_the_password
    Mutineer::DaemonServer.instance_variable_set(:@worker_db, LeakyWorkerDb)

    reply = Mutineer::DaemonServer.send(:provision_slots, 2)

    refute reply["ok"]
    assert_includes reply["error"], "postgres://u:[REDACTED]@ho st/db"
    refute_includes reply["error"], "s3cret"
  end

  def test_coverage_reply_and_log_hide_the_password
    errio = StringIO.new
    Mutineer::DaemonServer.instance_variable_set(:@errio, errio)
    Mutineer::DaemonServer.instance_variable_set(:@cfg, {})

    reply = Mutineer::CoverageMap.stub(:new, ->(**) { raise "no connection: #{BAD_URL}" }) do
      Mutineer::DaemonServer.send(:build_coverage_map)
    end

    assert_includes reply["error"], "[REDACTED]"
    refute_includes reply["error"] + errio.string, "s3cret"
  end

  def test_child_error_log_hides_the_password
    Tempfile.create("daemon_err") do |errio|
      errio.sync = true
      daemon = Mutineer::DaemonServer
      daemon.instance_variable_set(:@errio, errio)
      daemon.instance_variable_set(:@worker_db, LeakyWorkerDb)
      daemon.instance_variable_set(:@slot_ready, {})
      daemon.instance_variable_set(:@source_dirs, [])

      result = daemon.send(:run_mutant, "id" => 1, "worker" => 0, "timeout" => 10)

      assert_equal "error", result["verdict"]
      log = File.read(errio.path)
      assert_includes log, "[REDACTED]"
      refute_includes log, "s3cret"
    end
  end

  def test_worker_db_load_error_log_hides_the_password
    errio = StringIO.new
    Mutineer::DaemonServer.instance_variable_set(:@errio, errio)
    require "mutineer/rails_worker_db"

    Mutineer::RailsWorkerDb.stub(:available?, -> { raise LoadError, "cannot load adapter for #{BAD_URL}" }) do
      Mutineer::DaemonServer.send(:setup_worker_db, {})
    end

    assert_includes errio.string, "worker-DB routing unavailable"
    assert_includes errio.string, "[REDACTED]"
    refute_includes errio.string, "s3cret"
  end

  def test_redact_hides_a_malformed_password_with_a_space_or_a_quote
    ENV["DATABASE_URL"] = %(postgres://u:sec ret"x@host/db)

    quoted = Mutineer::DaemonServer.send(:redact, %(bad URI: "postgres://u:sec ret@ho st/db"))
    raw = Mutineer::DaemonServer.send(:redact, %(bad URI: "postgres://u:sec ret"x@host/db"))

    assert_equal %(bad URI: "postgres://u:[REDACTED]@ho st/db"), quoted
    refute_includes raw, "sec ret"
  end

  def test_redact_hides_the_database_url_password_outside_a_url
    ENV["DATABASE_URL"] = "postgres://u:p%40ss+w@host/db"

    text = Mutineer::DaemonServer.send(:redact, "auth failed: p@ss+w (p%40ss+w)")

    assert_equal "auth failed: [REDACTED] ([REDACTED])", text
  end

  def test_redact_leaves_text_without_credentials_alone
    ENV.delete("DATABASE_URL")
    text = "PG::ConnectionBad: could not connect to http://host:5432/db"

    assert_equal text, Mutineer::DaemonServer.send(:redact, text)
  end

  # #288: the daemon's stderr (which also carries the app's stdout) reaches the
  # tool's stderr through the client's drain, one redacted line at a time.
  def drain(bytes)
    errio = StringIO.new
    client = Mutineer::DaemonClient.new(boot: {}, app_root: Dir.tmpdir, errio: errio)
    rd, wr = IO.pipe
    wr.binmode
    wr.write(bytes)
    wr.close
    client.send(:drain_stderr, rd)
    errio.string
  ensure
    rd&.close
  end

  def test_daemon_stderr_drain_hides_the_password
    out = drain("boot failed: #{BAD_URL}\nsecond line\n")

    assert_includes out, "postgres://u:[REDACTED]@ho st/db"
    assert_includes out, "second line"
    refute_includes out, "s3cret"
  end

  def test_daemon_stderr_drain_survives_invalid_bytes
    out = drain("bad \xFF byte #{BAD_URL}\n".b)

    assert_includes out, "[REDACTED]"
    refute_includes out, "s3cret"
  end

  # After a tool stderr has gone away (EPIPE), the drain drops lines but keeps
  # reading, so the daemon never blocks, and it ends quietly, so close_io's
  # join cannot re-raise the error mid-cleanup.
  def test_daemon_stderr_drain_survives_a_broken_errio
    errio = Object.new
    def errio.write(*) = raise(Errno::EPIPE)
    client = Mutineer::DaemonClient.new(boot: {}, app_root: Dir.tmpdir, errio: errio)
    rd, wr = IO.pipe
    wr.write("line\n" * 100)
    wr.close

    assert_nil client.send(:drain_stderr, rd)
    assert_predicate rd, :eof?, "the drain must keep reading so the daemon never blocks on a full pipe"
  ensure
    rd&.close
  end

  def test_daemon_stderr_drain_keeps_line_breaks_when_redaction_fails_closed
    failed = Mutineer::Redaction::FAILED
    out = Mutineer::Redaction.stub(:text, failed) { drain("one\ntwo\n") }

    assert_equal "#{failed}\n#{failed}\n", out
  end

  def test_close_io_lets_the_drain_finish_a_last_partial_line
    errio = StringIO.new
    client = Mutineer::DaemonClient.new(boot: {}, app_root: Dir.tmpdir, errio: errio)
    rd, wr = IO.pipe
    client.instance_variable_set(:@stderr, rd)
    client.instance_variable_set(:@drain, Thread.new { client.send(:drain_stderr, rd) })
    wr.write("boot failed: #{BAD_URL}")
    wr.close

    client.send(:close_io)

    assert_equal "boot failed: postgres://u:[REDACTED]@ho st/db", errio.string
  end

  def test_daemon_stderr_drain_keeps_a_last_partial_line
    assert drain("first\ntail without newline").end_with?("tail without newline")
  end
end
