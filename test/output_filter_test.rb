# frozen_string_literal: true

require "minitest/mock"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "test_helper"
require "mutineer/output_filter"
require "mutineer/cli"

# The copier is the mechanism: a line written to the real descriptor comes
# back redacted, with the words around the password still there. Dropping the
# line, or hiding only a URL, would fail these.
class OutputFilterTest < Minitest::Test
  BIN = File.expand_path("../bin/mutineer", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  def setup
    @saved_url = ENV.fetch("DATABASE_URL", nil)
    ENV.delete("DATABASE_URL")
    Mutineer::Redaction.extra_urls = []
  end

  def teardown
    Mutineer::OutputFilter.uninstall
    @saved_url ? ENV["DATABASE_URL"] = @saved_url : ENV.delete("DATABASE_URL")
    Mutineer::Redaction.extra_urls = []
  end

  def test_copies_stdio_and_a_fork_child_through_redaction
    ENV["DATABASE_URL"] = "postgres://u:s3cret@h/db"
    out, err = captured do
      Mutineer::OutputFilter.install
      STDOUT.puts "boot-out s3cret tail"
      STDERR.puts "boot-err s3cret tail"
      STDOUT.print "partial s3cret"
      pid = fork do
        STDERR.puts "child-err s3cret tail"
        exit!(0)
      end
      Process.waitpid(pid)
    end

    assert_equal "boot-out [REDACTED] tail\npartial [REDACTED]", out
    assert_includes err, "boot-err [REDACTED] tail"
    assert_includes err, "child-err [REDACTED] tail"
    refute_includes out + err, "s3cret"
  end

  def test_a_line_without_a_password_keeps_its_bytes
    out, err = captured do
      Mutineer::OutputFilter.install
      STDOUT.puts "hello"
      STDERR.print "no newline"
    end

    assert_equal "hello\n", out
    assert_equal "no newline", err
  end

  def test_a_fork_that_sets_the_url_hides_the_bare_password
    out, err = captured do
      Mutineer::OutputFilter.install(streams: [:stderr])
      pid = fork do
        ENV["DATABASE_URL"] = "postgres://u:s3cret@h/db"
        STDERR.puts "child s3cret end"
        exit!(0)
      end
      Process.waitpid(pid)
    end

    assert_includes err, "child [REDACTED] end"
    refute_includes err, "s3cret"
    assert_empty out
  end

  def test_a_password_with_a_newline_is_not_split
    ENV["DATABASE_URL"] = "postgres://u:#{["foo", "\n", "bar"].join}@h/db"
    _out, err = captured do
      Mutineer::OutputFilter.install(streams: [:stderr])
      STDERR.puts "leak foo\nbar end"
    end

    assert_includes err, "leak [REDACTED] end"
    refute_includes err, "foo"
    refute_includes err, "bar"

    secret = ["foo", "\n", "bar"].join
    _out, bare = captured do
      Mutineer::OutputFilter.install(streams: [:stderr])
      STDERR.print secret
    end

    assert_equal "[REDACTED]", bare
    refute_includes bare, "foo"
    refute_includes bare, "bar"
  end

  def test_a_fork_child_that_cannot_start_its_copier_prints_nothing
    secret = ["s3", "cret"].join
    out, err = captured do
      Mutineer::OutputFilter.install(streams: [:stderr])
      Mutineer::OutputFilter.stub(:stream_io, ->(*) { raise IOError, "closed" }) do
        pid = fork do
          ENV["DATABASE_URL"] = "postgres://u:#{secret}@h/db"
          STDOUT.puts "child-out #{secret} end"
          STDERR.puts "child #{secret} end"
          exit!(0)
        end
        Process.waitpid(pid)
      end
    end

    refute_includes out + err, secret
    refute_includes out + err, "child"
  end

  # A fork child's copier does not survive exec. The program writes to the
  # parent's pipe, and the parent redacts it with the parent's environment.
  def test_a_fork_child_that_execs_still_reaches_the_parent_pipe
    ENV["DATABASE_URL"] = "postgres://u:s3cret@h/db"
    _out, err = captured do
      Mutineer::OutputFilter.install(streams: [:stderr])
      pid = fork { exec(RbConfig.ruby, "-e", "STDERR.puts %(execd s3cret end)") }
      Process.waitpid(pid)
    end

    assert_includes err, "execd [REDACTED] end"
    refute_includes err, "s3cret"
  end

  # The report is larger than a pipe buffer and the reader waits longer than
  # the old shutdown kill. Every byte still arrives.
  def test_uninstall_writes_a_report_a_slow_reader_has_not_taken
    real = STDOUT.dup
    read, write = IO.pipe
    write.sync = true
    STDOUT.reopen(write)
    payload = ("A" * 200_000) + "\n"
    got = +""
    reader = Thread.new do
      sleep 0.3
      loop do
        chunk = read.read_nonblock(65_536, exception: false)
        break if chunk.nil?
        if chunk == :wait_readable
          break unless read.wait_readable(1)

          next
        end
        got << chunk
      end
    end
    Mutineer::OutputFilter.install(streams: [:stdout])
    STDOUT.write(payload)
    Mutineer::OutputFilter.uninstall
    write.close unless write.closed?
    reader.join(2)

    assert_equal payload, got
  ensure
    STDOUT.reopen(real) if real && !real.closed?
    real&.close
    write&.close unless write&.closed?
    read&.close unless read&.closed?
    Mutineer::OutputFilter.uninstall
  end

  def test_a_replaced_stderr_receives_the_redacted_line
    ENV["DATABASE_URL"] = "postgres://u:s3cret@h/db"
    assert_equal :started, Mutineer::OutputFilter.install(streams: [:stderr])
    captured = StringIO.new
    previous = $stderr
    begin
      $stderr = captured
      STDERR.puts "leak s3cret done"
      Mutineer::OutputFilter.uninstall
    ensure
      $stderr = previous
    end

    assert_equal "leak [REDACTED] done\n", captured.string
  end

  # A grandchild that inherits the pipe must not make uninstall wait the way
  # the old daemon drain waited out DRAIN_GRACE (#341).
  def test_uninstall_does_not_wait_on_a_pipe_a_grandchild_holds
    Mutineer::OutputFilter.install(streams: [:stderr])
    pid = fork { sleep 30 }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Mutineer::OutputFilter.uninstall
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.5
  ensure
    if pid
      Process.kill(:KILL, pid) rescue nil
      Process.waitpid(pid) rescue nil
    end
  end

  def test_a_failed_install_closes_the_pipes_it_opened
    opened = []
    pipe = IO.method(:pipe)
    IO.stub(:pipe, ->(*args) {
      pair = pipe.call(*args)
      opened.concat(pair)
      pair
    }) do
      Mutineer::OutputFilter.stub(:stream_io, lambda { |name|
        raise IOError, "closed" if name == :stdout

        STDERR
      }) do
        assert_equal :failed, Mutineer::OutputFilter.install(streams: [:stderr, :stdout])
      end
    end

    refute_empty opened
    opened.each { |io| assert_predicate io, :closed? }
    refute Mutineer::OutputFilter.installed?
  end

  def test_install_twice_starts_one_copier
    assert_equal :started, Mutineer::OutputFilter.install
    assert_equal :already, Mutineer::OutputFilter.install
  ensure
    Mutineer::OutputFilter.uninstall
    refute Mutineer::OutputFilter.installed?
  end

  def test_cli_redacts_boot_stdio_a_fork_and_a_spawned_child
    Dir.mktmpdir do |proj|
      File.write(File.join(proj, "calc.rb"), "class Calc; def add(a, b) = a + b; end\n")
      File.write(File.join(proj, "calc_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "calc"
        class CalcTest < Minitest::Test
          def test_add
            STDERR.puts "child-err s3cret tail"
            system(#{RbConfig.ruby.inspect}, "-e", 'STDERR.puts "spawn-err s3cret tail"')
            assert_equal 3, Calc.new.add(1, 2)
          end
        end
      RUBY
      File.write(File.join(proj, "boot.rb"), <<~RUBY)
        STDERR.puts "boot-err s3cret tail"
        STDOUT.puts "boot-out s3cret tail"
      RUBY
      out, err, status = mutineer("run", "calc.rb", "--test", "calc_test.rb", "--boot", "boot.rb", "--jobs", "1",
                                  chdir: proj, env: { "DATABASE_URL" => "postgres://u:s3cret@h/db" })

      assert_equal 0, status.exitstatus, err
      %w[boot-err boot-out child-err spawn-err].each do |marker|
        assert_includes out + err, "#{marker} [REDACTED] tail", "#{marker} missing from:\n#{out}\n#{err}"
      end
      refute_includes out + err, "s3cret"
    end
  end

  def test_cli_redacts_an_abort_in_the_boot_file
    Dir.mktmpdir do |proj|
      File.write(File.join(proj, "calc.rb"), "class Calc; def add(a, b) = a + b; end\n")
      File.write(File.join(proj, "calc_test.rb"), "require \"minitest/autorun\"\n")
      File.write(File.join(proj, "boot.rb"), "abort \"aborted s3cret now\"\n")
      _out, err, status = mutineer("run", "calc.rb", "--test", "calc_test.rb", "--boot", "boot.rb",
                                   chdir: proj, env: { "DATABASE_URL" => "postgres://u:s3cret@h/db" })

      refute_equal 0, status.exitstatus
      assert_includes err, "aborted [REDACTED] now"
      refute_includes err, "s3cret"
    end
  end

  def test_cli_redacts_a_password_the_boot_file_assigns
    Dir.mktmpdir do |proj|
      File.write(File.join(proj, "calc.rb"), "class Calc; def add(a, b) = a + b; end\n")
      File.write(File.join(proj, "calc_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "calc"
        class CalcTest < Minitest::Test
          def test_add = assert_equal(3, Calc.new.add(1, 2))
        end
      RUBY
      File.write(File.join(proj, "boot.rb"), <<~RUBY)
        ENV["DATABASE_URL"] = "postgres://u:s3cret@h/db"
        STDERR.puts "assigned s3cret tail"
      RUBY
      _out, err, status = mutineer("run", "calc.rb", "--test", "calc_test.rb", "--boot", "boot.rb", "--jobs", "1",
                                   chdir: proj, env: { "DATABASE_URL" => nil })

      assert_equal 0, status.exitstatus, err
      assert_includes err, "assigned [REDACTED] tail"
      refute_includes err, "s3cret"
    end
  end

  def test_test_command_hides_a_bare_password_from_a_dotenv_file
    Dir.mktmpdir do |proj|
      File.write(File.join(proj, ".env"), "DATABASE_URL=postgres://u:s3cret@h/db\n")
      # An arithmetic mutant, so the run reaches the test command. With no
      # mutant the smoke check is skipped and the command never prints.
      File.write(File.join(proj, "a.rb"), "class A; def add(a, b) = a + b; end\n")
      File.write(File.join(proj, "a_test.rb"), "def test_a = 1\n")
      command = "#{RbConfig.ruby} -e 'STDERR.puts %{cmd s3cret tail}; exit 1' %{files}"
      _out, err, status = mutineer("run", "a.rb", "--test", "a_test.rb", "--test-command", command,
                                   chdir: proj, env: { "DATABASE_URL" => nil })

      assert_equal 1, status.exitstatus
      assert_includes err, "cmd [REDACTED] tail"
      refute_includes err, "s3cret"
    end
  end

  # The command's own process can set a password that is not in the
  # environment and not in a dotenv file. The bare word stays. A URL would
  # still be hidden. This is the limit of what the parent can know.
  def test_test_command_leaves_a_bare_password_set_only_inside_the_command
    Dir.mktmpdir do |proj|
      File.write(File.join(proj, "a.rb"), "class A; def add(a, b) = a + b; end\n")
      File.write(File.join(proj, "a_test.rb"), "def test_a = 1\n")
      # The URL is assembled in the child so this source has no credential literal.
      command = "#{RbConfig.ruby} -e 'ENV[%{DATABASE_URL}] = %{postgres://u:} + %{in} + %{command} + %{@h/db}; STDERR.puts %{only incommand tail}; exit 1' %{files}"
      _out, err, status = mutineer("run", "a.rb", "--test", "a_test.rb", "--test-command", command,
                                   chdir: proj, env: { "DATABASE_URL" => nil })

      assert_equal 1, status.exitstatus, err
      assert_includes err, "only incommand tail"
    end
  end

  def captured
    real_out = STDOUT.dup
    real_err = STDERR.dup
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    out_w.sync = true
    err_w.sync = true
    STDOUT.reopen(out_w)
    STDERR.reopen(err_w)
    yield
    Mutineer::OutputFilter.uninstall
    [read_ready(out_r), read_ready(err_r)]
  ensure
    Mutineer::OutputFilter.uninstall
    STDOUT.reopen(real_out) if real_out && !real_out.closed?
    STDERR.reopen(real_err) if real_err && !real_err.closed?
    [real_out, real_err, out_w, err_w, out_r, err_r].compact.each do |io|
      io.close unless io.closed?
    end
  end

  def read_ready(io)
    return "" if io.nil? || io.closed?

    got = +""
    loop do
      chunk = io.read_nonblock(4096, exception: false)
      break if chunk.nil? || chunk == :wait_readable

      got << chunk
    end
    got
  end

  def mutineer(*args, chdir:, env:)
    Open3.capture3(env, RbConfig.ruby, "-I#{LIB}", BIN, *args, chdir: chdir)
  end
end
