# frozen_string_literal: true

require "minitest/mock"
require "tempfile"
require_relative "test_helper"
require "mutineer/daemon_server"

# A second boot sweeps source dirs before it can take the database lock.
# That sweep must not delete a mutant file another live process still owns.
class DaemonTempSweepTest < Minitest::Test
  def test_sweep_temps_keeps_a_live_mutant_file_and_removes_a_dead_one
    pid = nil
    Dir.mktmpdir do |dir|
      reader, writer = IO.pipe
      begin
        stale = File.join(dir, "mutineer_daemon20200101-#{unused_pid}-stale.rb")
        File.write(stale, "class Order; end\n")
        pid = fork do
          reader.close
          Tempfile.create([".mutineer_daemon", ".rb"], dir) do |file|
            file.flock(File::LOCK_EX)
            file.write("class Order; end\n")
            file.flush
            writer.puts file.path
            writer.close
            sleep 30
          end
        end
        writer.close
        path = read_child_path(reader)
        Mutineer::DaemonServer.instance_variable_set(:@source_dirs, [dir])

        Mutineer::DaemonServer.send(:sweep_temps)

        assert File.exist?(path), "a live run's mutant file must stay"
        refute File.exist?(stale), "a dead owner's file is an orphan"

        Process.kill(:KILL, pid)
        Process.waitpid(pid)
        pid = nil
        Mutineer::DaemonServer.send(:sweep_temps)
        refute File.exist?(path), "the file goes once its owner is gone"
      ensure
        writer.close unless writer.closed?
        reader.close unless reader.closed?
        if pid
          Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          Process.waitpid(pid) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
    end
  ensure
    Mutineer::DaemonServer.instance_variable_set(:@source_dirs, nil)
  end

  def test_sweep_temps_keeps_a_locked_file_when_the_name_pid_is_dead
    pid = nil
    Dir.mktmpdir do |dir|
      reader, writer = IO.pipe
      begin
        path = File.join(dir, "mutineer_daemon20200101-#{unused_pid}-locked.rb")
        pid = fork do
          reader.close
          File.open(path, "w") do |file|
            file.write("class Order; end\n")
            file.flush
            file.flock(File::LOCK_EX)
            writer.puts "locked"
            writer.close
            sleep 30
          end
        end
        writer.close
        flunk "child did not lock the file" unless IO.select([reader], nil, nil, 5)

        assert_equal "locked", reader.gets&.strip
        Mutineer::DaemonServer.instance_variable_set(:@source_dirs, [dir])
        Mutineer::DaemonServer.send(:sweep_temps)
        assert File.exist?(path), "a lock means another process still owns the file"
      ensure
        writer.close unless writer.closed?
        reader.close unless reader.closed?
        if pid
          Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          Process.waitpid(pid) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
    end
  ensure
    Mutineer::DaemonServer.instance_variable_set(:@source_dirs, nil)
  end

  def test_tool_side_sweep_also_keeps_a_live_daemon_file
    pid = nil
    Dir.mktmpdir do |dir|
      reader, writer = IO.pipe
      begin
        stale = File.join(dir, "mutineer_daemon20200101-#{unused_pid}-stale.rb")
        File.write(stale, "class Order; end\n")
        pid = fork do
          reader.close
          Tempfile.create([".mutineer_daemon", ".rb"], dir) do |file|
            file.write("class Order; end\n")
            file.flush
            writer.puts file.path
            writer.close
            sleep 30
          end
        end
        writer.close
        path = read_child_path(reader)

        Mutineer::JobPlan.sweep_orphans([dir], Mutineer::DaemonBackend::DAEMON_TEMP_GLOB)

        assert File.exist?(path)
        refute File.exist?(stale)
      ensure
        writer.close unless writer.closed?
        reader.close unless reader.closed?
        if pid
          Process.kill(:KILL, pid) rescue nil # rubocop:disable Style/RescueModifier
          Process.waitpid(pid) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
    end
  end

  # #250: where pid 1 does not reap orphans (a container without init), a
  # killed mutant child stays a zombie. It owns nothing, so its file goes.
  def test_sweep_removes_a_file_whose_owner_is_a_zombie
    skip "zombie detection reads /proc (Linux only)" unless File.exist?("/proc/self/stat")

    zombie = fork { exit!(0) }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until File.read("/proc/#{zombie}/stat").split(") ").last.start_with?("Z") ||
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mutineer_daemon20200101-#{zombie}-zombie.rb")
      File.write(path, "module ZombieOwned; end\n")

      assert_empty Mutineer::JobPlan.sweep_orphans([dir], Mutineer::DaemonBackend::DAEMON_TEMP_GLOB)
      refute_path_exists path, "a zombie owner must not keep its file"
    end
  ensure
    Process.waitpid(zombie) if zombie
  end

  # The state follows the LAST ") ", since the name may hold one itself. An
  # empty read (the process exited mid-read) is not a zombie, and must not
  # raise past the sweep's SystemCallError rescue. Runs on every OS.
  def test_zombie_check_reads_the_state_after_the_name_and_survives_an_empty_read
    File.stub(:read, "4242 (a) Z b) S 1 1\n") { refute Mutineer::OrphanGuard.send(:zombie?, 4242) }
    File.stub(:read, "4242 (a) S b) Z 1 1\n") { assert Mutineer::OrphanGuard.send(:zombie?, 4242) }
    File.stub(:read, "") { refute Mutineer::OrphanGuard.send(:zombie?, 4242) }
  end

  # #253: the daemon writes its mutant file hidden, so Zeitwerk never lists it,
  # and both cleanup globs still match it.
  def test_the_daemon_writes_a_hidden_mutant_file_the_globs_match
    Dir.mktmpdir do |dir|
      code = "$mutant_file = __FILE__\n"
      Mutineer::DaemonServer.send(:apply_payload, "source_file" => File.join(dir, "x.rb"), "code" => code)
      name = File.basename($mutant_file)

      assert_match(/\A\.mutineer_daemon\d{8}-#{Process.pid}-/, name)
      [Mutineer::OrphanGuard::TEMP_BASENAME, Mutineer::DaemonBackend::DAEMON_TEMP_GLOB].each do |glob|
        assert File.fnmatch?(glob, name, File::FNM_EXTGLOB), glob
      end
    end
  end

  # #287: the daemon boot sweep also removes an old in-process file, which
  # would stop the boot, and keeps one a live in-process run still owns.
  def test_sweep_temps_removes_an_old_in_process_file
    Dir.mktmpdir do |dir|
      old = File.join(dir, "mutineer_mutant20200101-#{unused_pid}-old.rb")
      live = File.join(dir, ".mutineer_mutant20200101-#{Process.pid}-live.rb")
      [old, live].each { |f| File.write(f, "") }
      Mutineer::DaemonServer.instance_variable_set(:@source_dirs, [dir])

      Mutineer::DaemonServer.send(:sweep_temps)

      refute File.exist?(old), "an old in-process file must not stop the daemon boot"
      assert File.exist?(live), "a live in-process run's file must stay"
    end
  ensure
    Mutineer::DaemonServer.instance_variable_set(:@source_dirs, nil)
  end

  def read_child_path(reader)
    flunk "child did not create the mutant file" unless IO.select([reader], nil, nil, 5)

    path = reader.gets&.strip
    flunk "child did not report a path" if path.nil? || path.empty?

    path
  end
end
