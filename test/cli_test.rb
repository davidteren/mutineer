# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# Drives bin/brutus as a real subprocess so flag parsing, validation exit codes,
# and --list-operators are exercised end to end.
class CliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN  = File.join(ROOT, "bin", "brutus")

  def brutus(*args)
    Open3.capture3(RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}", BIN, *args, chdir: Dir.tmpdir)
  end

  def test_list_operators_shows_default_and_disabled
    out, _, status = brutus("--list-operators")
    assert_equal 0, status.exitstatus
    assert_match(/arithmetic\s+tier 1\s+default/, out)
    assert_match(/return_nil\s+tier 2\s+disabled/, out)
    assert_match(/literal_mutation\s+tier 2\s+disabled/, out)
    assert_match(/condition_negation\s+tier 2\s+disabled/, out)
  end

  def test_jobs_zero_exits_one
    _, err, status = brutus("run", "x.rb", "--jobs", "0")
    assert_equal 1, status.exitstatus
    assert_includes err, "--jobs requires a positive integer"
  end

  def test_unknown_format_exits_one
    _, err, status = brutus("run", "x.rb", "--format", "csv")
    assert_equal 1, status.exitstatus
    assert_includes err, %(unknown format "csv")
  end

  def test_unknown_strategy_exits_one
    _, err, status = brutus("run", "x.rb", "--strategy", "bogus")
    assert_equal 1, status.exitstatus
    assert_includes err, %(unknown strategy "bogus")
  end

  def test_unwritable_output_exits_one
    _, err, status = brutus("run", "x.rb", "--test", "t.rb", "--output", "/no-such-dir/out.json")
    assert_equal 1, status.exitstatus
    assert_includes err, "cannot write to"
  end
end
