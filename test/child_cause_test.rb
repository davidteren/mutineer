# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "timeout"
require "mutineer/child_cause"

# The one line a mutant's child sends its parent: why it raised (#388).
class ChildCauseTest < Minitest::Test
  URL = "postgres://u:s3cret@ho st/db"

  def test_line_names_the_class_and_the_first_line_that_is_not_blank
    assert_equal "ArgumentError: enum declared twice",
                 Mutineer::ChildCause.line(ArgumentError.new("enum declared twice"))
    assert_equal "RuntimeError: Migrations are pending.",
                 Mutineer::ChildCause.line(RuntimeError.new("\n  \nMigrations are pending.\nrun bin/rails db:migrate"))
  end

  def test_line_is_the_class_alone_without_a_message
    assert_equal "IOError", Mutineer::ChildCause.line(IOError.new)
    assert_equal "IOError", Mutineer::ChildCause.line(IOError.new(""))
  end

  def test_line_is_cut_to_the_limit
    line = Mutineer::ChildCause.line(RuntimeError.new("€" * 2_000))

    assert_equal Mutineer::ChildCause::LIMIT, line.length
    assert line.valid_encoding?
    assert line.end_with?("...")
  end

  # The cut comes after redaction: cutting first would leave `s3c` behind the
  # URL's head, where no full password is left to match.
  def test_line_is_redacted_before_the_cut
    with_database_url(nil) do
      line = Mutineer::ChildCause.line(RuntimeError.new("#{"x" * 467}#{URL}"))

      refute_includes line, "s3c"
    end
  end

  def test_line_hides_the_database_password
    with_database_url(URL) do
      line = Mutineer::ChildCause.line(RuntimeError.new("no connection: #{URL}"))

      assert_equal "RuntimeError: no connection: postgres://u:[REDACTED]@ho st/db", line
    end
  end

  def test_line_fails_closed
    error = RuntimeError.new
    def error.message = raise("no message")

    assert_equal Mutineer::Redaction::FAILED, Mutineer::ChildCause.line(error)
  end

  # Both fork boundaries end with `exit!`, which flushes nothing.
  def test_a_written_line_reaches_the_parent_as_utf8
    rd, wr = IO.pipe
    wr.sync = true
    pid = fork do
      rd.close
      Mutineer::ChildCause.write(wr, RuntimeError.new("café"))
      exit!(2)
    end
    wr.close
    Process.wait(pid)
    line = Mutineer::ChildCause.read(rd)

    assert_equal "RuntimeError: café", line
    assert_equal Encoding::UTF_8, line.encoding
    JSON.generate("details" => line)
  ensure
    rd&.close
    wr&.close unless wr&.closed?
  end

  def test_read_takes_the_last_complete_line_and_skips_a_partial_one
    rd, wr = IO.pipe
    wr.write("A: one\nB: two\nC: thr")

    assert_equal "B: two", Mutineer::ChildCause.read(rd)
  ensure
    rd.close
    wr.close
  end

  def test_read_replaces_invalid_bytes
    rd, wr = IO.pipe
    wr.write("X: \xFF\n".b)

    assert_equal "X: �", Mutineer::ChildCause.read(rd)
  ensure
    rd.close
    wr.close
  end

  # A grandchild can keep the write end open; the read must not wait for it.
  def test_read_does_not_block_on_an_open_empty_pipe
    rd, wr = IO.pipe

    assert_nil Timeout.timeout(2) { Mutineer::ChildCause.read(rd) }
  ensure
    rd.close
    wr.close
  end

  private

  def with_database_url(url)
    saved = ENV.fetch("DATABASE_URL", nil)
    ENV["DATABASE_URL"] = url
    yield
  ensure
    ENV["DATABASE_URL"] = saved
  end
end
