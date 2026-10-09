# frozen_string_literal: true

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
          Tempfile.create(["mutineer_daemon", ".rb"], dir) do |file|
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
          Tempfile.create(["mutineer_daemon", ".rb"], dir) do |file|
            file.write("class Order; end\n")
            file.flush
            writer.puts file.path
            writer.close
            sleep 30
          end
        end
        writer.close
        path = read_child_path(reader)

        Mutineer::JobPlan.sweep_orphans([dir], "mutineer_daemon*.rb")

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

  def unused_pid
    (100_000..100_500).find do |candidate|
      Process.kill(0, candidate)
      false
    rescue Errno::ESRCH
      true
    rescue Errno::EPERM
      false
    end || flunk("no unused pid")
  end

  def read_child_path(reader)
    flunk "child did not create the mutant file" unless IO.select([reader], nil, nil, 5)

    path = reader.gets&.strip
    flunk "child did not report a path" if path.nil? || path.empty?

    path
  end
end
