# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

# `mutineer triage` prints ignore entries and does not edit files.
class TriageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "mutineer")
  FIXTURES = File.expand_path("fixtures", __dir__)

  def mutineer(*args, chdir:)
    Open3.capture3(RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}", BIN, *args, chdir: chdir)
  end

  def write_report(dir, ids)
    rows = ids.map { |id| { "id" => id } }
    File.write(File.join(dir, "report.json"), JSON.generate("schema_version" => "1.8", "survivors" => rows))
  end

  def test_all_prints_one_mapping_per_survivor_and_does_not_edit_files
    Dir.mktmpdir("mutineer-triage") do |dir|
      write_report(dir, %w[aaaaaaaaaaaa bbbbbbbbbbbb cccccccccccc])
      before = Dir.children(dir).sort
      out, err, status = mutineer("triage", "report.json", "--all", "--reason", "x", chdir: dir)
      assert_equal 0, status.exitstatus, err
      assert_empty err
      assert_equal before, Dir.children(dir).sort
      assert_equal [
        { "id" => "aaaaaaaaaaaa", "reason" => "x" },
        { "id" => "bbbbbbbbbbbb", "reason" => "x" },
        { "id" => "cccccccccccc", "reason" => "x" }
      ], YAML.safe_load(out)
    end
  end

  # An empty selection must not print "--- []". That text is not valid under ignore:.
  def test_all_with_no_survivors_says_there_is_nothing_to_paste
    Dir.mktmpdir("mutineer-triage") do |dir|
      write_report(dir, [])
      out, err, status = mutineer("triage", "report.json", "--all", "--reason", "x", chdir: dir)
      assert_equal 0, status.exitstatus, err
      assert_includes err, "nothing to paste under ignore:"
      assert_empty out
      File.write(File.join(dir, ".mutineer.yml"), "ignore:\n#{out}")
      loaded = nil
      _stdout, warn = capture_io { loaded = Mutineer::Config.from_file(File.join(dir, ".mutineer.yml")) }
      assert_empty warn
      assert_equal [], loaded[:ignore]
    end
  end

  # A report that exists but cannot be read is a usage error, not a crash.
  def test_an_unreadable_report_exits_two
    Dir.mktmpdir("mutineer-triage") do |dir|
      path = File.join(dir, "report.json")
      File.write(path, JSON.generate("survivors" => [{ "id" => "aaaaaaaaaaaa" }]))
      denied = false
      begin
        File.chmod(0o000, path)
        denied = !File.readable?(path)
      rescue SystemCallError
        denied = false
      end

      if denied
        _out, err, status = mutineer("triage", "report.json", "--all", "--reason", "x", chdir: dir)
        assert_equal 2, status.exitstatus
        assert_includes err, "cannot be read: report.json"
        refute_includes err, "triage.rb"
      else
        err = StringIO.new
        out = StringIO.new
        code = File.stub(:read, ->(*) { raise Errno::EACCES, path }) do
          Mutineer::Triage.run([path, "--all", "--reason", "x"], out: out, err: err)
        end
        assert_equal 2, code
        assert_includes err.string, "cannot be read: #{path}"
        assert_empty out.string
      end
    ensure
      File.chmod(0o644, path) if path && File.exist?(path)
    end
  end

  def test_one_id_prints_one_entry
    Dir.mktmpdir("mutineer-triage") do |dir|
      write_report(dir, %w[aaaaaaaaaaaa bbbbbbbbbbbb])
      out, err, status = mutineer("triage", "report.json", "--id", "bbbbbbbbbbbb", "--reason", "x", chdir: dir)
      assert_equal 0, status.exitstatus, err
      assert_equal [{ "id" => "bbbbbbbbbbbb", "reason" => "x" }], YAML.safe_load(out)
    end
  end

  def test_an_id_that_is_not_a_survivor_exits_two_and_names_it
    Dir.mktmpdir("mutineer-triage") do |dir|
      write_report(dir, %w[aaaaaaaaaaaa])
      _out, err, status = mutineer("triage", "report.json", "--id", "dddddddddddd", "--reason", "x", chdir: dir)
      assert_equal 2, status.exitstatus
      assert_includes err, "dddddddddddd"
    end
  end

  def test_a_missing_or_blank_reason_or_no_selection_exits_two
    Dir.mktmpdir("mutineer-triage") do |dir|
      write_report(dir, %w[aaaaaaaaaaaa])
      _out, err, status = mutineer("triage", "report.json", "--all", chdir: dir)
      assert_equal 2, status.exitstatus
      assert_includes err, "--reason"

      _out, err, status = mutineer("triage", "report.json", "--all", "--reason", "   ", chdir: dir)
      assert_equal 2, status.exitstatus
      assert_includes err, "--reason"

      _out, err, status = mutineer("triage", "report.json", "--reason", "x", chdir: dir)
      assert_equal 2, status.exitstatus
      assert_includes err, "--id"
    end
  end

  # Paste the printed lines under ignore:. The next run ignores those mutants
  # and keeps the reason.
  def test_printed_entries_load_and_a_follow_up_run_reports_the_reason
    Dir.mktmpdir("mutineer-triage") do |proj|
      %w[calculator.rb calculator_weak_test.rb].each do |name|
        FileUtils.cp(File.join(FIXTURES, name), File.join(proj, name))
      end
      _out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                                   "--operators", "arithmetic", "--format", "json",
                                   "--output", "report.json", "--jobs", "1", chdir: proj)
      assert_equal 0, status.exitstatus, err
      survivors = JSON.parse(File.read(File.join(proj, "report.json")))["survivors"]
      refute_empty survivors

      printed, err, status = mutineer("triage", "report.json", "--all", "--reason", "same value", chdir: proj)
      assert_equal 0, status.exitstatus, err
      File.write(File.join(proj, ".mutineer.yml"), "ignore:\n#{printed}")
      _out, warn = capture_io { Mutineer::Config.from_file(File.join(proj, ".mutineer.yml")) }
      assert_empty warn

      _out, err, status = mutineer("run", "calculator.rb", "--test", "calculator_weak_test.rb",
                                   "--operators", "arithmetic", "--format", "json",
                                   "--output", "again.json", "--jobs", "1", chdir: proj)
      assert_equal 0, status.exitstatus, err
      again = JSON.parse(File.read(File.join(proj, "again.json")))
      assert_empty again["survivors"]
      assert_equal survivors.map { |row| row["id"] }.sort, again["ignored"].map { |row| row["id"] }.sort
      again["ignored"].each { |row| assert_equal "same value", row["reason"] }
    end
  end
end
