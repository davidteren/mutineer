# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# Issue #434: Rails' assert_response appends a short body as raw bytes. The
# reporter then prints that message. Rails sets both Encoding.default_external
# and Encoding.default_internal to UTF-8 (`config.encoding`). A text-mode
# silenced stdout then transcodes the write and raises
# Encoding::UndefinedConversionError. The child's rescue scored that as
# `error`. The mutant had already failed the test, so the verdict is `killed`,
# and the matrix names the test that failed.
#
# Siblings: reload and redefine both silence stdout in Isolation. The daemon
# silences it in its own child and forces reload; redefine is in-process only.
# RSpec writes the failure text to a StringIO,
# which does not transcode, so that path already returned killed.
# `--test-command` does not reopen stdout after the encodings are set, so it
# is not this path.
class BinaryFailureMessageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SOURCE = File.join(ROOT, "test/fixtures/binary_body.rb")
  MINITEST = File.join(ROOT, "test/fixtures/binary_body_test.rb")
  RSPEC = File.join(ROOT, "test/fixtures/binary_body_spec.rb")
  BOOT = File.join(ROOT, "test/fixtures/binary_body_boot.rb")
  OPERATORS = %w[comparison literal_mutation condition_negation condition_true condition_false].freeze
  PREDICATE = 'id == "missing"'
  MISSING = '"missing"'
  # The else-branch literal, as source text. No test reaches it.
  BINARY = "\"\\xDA\\xFF\""
  MINITEST_KILLER = "BinaryBodyTest#test_missing_blob_is_not_found"
  RSPEC_KILLER = "BinaryBody reports a missing blob as not found"

  # operator, token => [status, killers or nil when the mutant is not run]
  def expected(killer)
    {
      ["comparison", "=="] => ["killed", [killer]],
      ["literal_mutation", MISSING] => ["killed", [killer]],
      ["literal_mutation", BINARY] => ["no_coverage", nil],
      ["condition_negation", PREDICATE] => ["killed", [killer]],
      ["condition_true", PREDICATE] => ["survived", []],
      ["condition_false", PREDICATE] => ["killed", [killer]]
    }
  end

  def test_fixture_pins_the_utf8_default_and_a_raw_failure_body
    assert_includes File.read(BOOT), "Encoding.default_external = Encoding::UTF_8"
    assert_includes File.read(BOOT), "Encoding.default_internal = Encoding::UTF_8"
    assert_includes File.read(MINITEST), 'Response body: #{body}'
    assert_includes File.read(RSPEC), 'Response body: #{body}'
  end

  def test_a_binary_failure_message_kills_the_mutant_and_names_the_test
    report = run_with_rails_encodings do
      {
        "minitest" => %w[reload redefine].to_h { |strategy| [strategy, run_suite(strategy:, framework: "minitest", tests: [MINITEST])] },
        "rspec" => { "reload" => run_suite(strategy: "reload", framework: "rspec", tests: [RSPEC]) }
      }
    end

    assert_rows report["minitest"]["reload"], MINITEST_KILLER
    assert_rows report["minitest"]["redefine"], MINITEST_KILLER
    assert_rows report["rspec"]["reload"], RSPEC_KILLER
  end

  def test_daemon_child_kills_a_mutant_whose_failure_message_is_binary
    source = File.read(SOURCE)
    subject = Mutineer::Project.discover([SOURCE]).first
    # The else branch holds the raw bytes and is not covered, so a real run
    # never forks those mutants. The daemon has no coverage map of its own.
    covered = mutations_for(subject, source).reject { |mutation| token(source, mutation).include?("\\xDA") }
    assert_equal 5, covered.size

    replies, err = daemon_replies([source, *covered.map { |mutation| mutation.apply(source) }])
    refute_includes err, "UndefinedConversionError"
    refute_includes err, "[daemon-child]"

    original, *mutants = replies
    assert_equal "survived", original
    covered.zip(mutants).each do |mutation, verdict|
      expected = mutation.replacement == "(true)" ? "survived" : "killed"
      assert_equal expected, verdict, "#{mutation.operator} #{token(source, mutation).inspect} => #{mutation.replacement.inspect}"
    end
  end

  private

  def assert_rows(report, killer)
    assert_equal 0, report["errored"]
    rows = report["rows"]
    assert_equal expected(killer).keys.sort, rows.map { |row| [row["operator"], row["token"]] }.sort
    rows.each do |row|
      status, killers = expected(killer).fetch([row["operator"], row["token"]])
      label = "#{row["operator"]} #{row["token"].inspect}"
      assert_equal "BinaryBody#show", row["subject"], label
      assert_nil row["details"], label
      assert_equal status, row["status"], label
      if killers.nil?
        assert_nil row["killers"], label
        next
      end

      assert_equal killers, row["killers"], label
      assert_equal [killer], row["ran"], label
      assert row["complete"], label
    end
  end

  def run_suite(strategy:, framework:, tests:)
    config = Mutineer::Config.new(
      sources: [SOURCE], tests: tests, operators: OPERATORS, matrix: true,
      strategy: strategy, framework: framework,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    aggregate, = Mutineer::Runner.execute(config)
    source = File.read(SOURCE)
    {
      "errored" => aggregate.errored_count,
      "rows" => aggregate.results.map { |result| row(result, source) }
    }
  end

  def row(result, source)
    kills = result.kills
    {
      "operator" => result.mutation.operator.to_s,
      "token" => token(source, result.mutation),
      "status" => result.status.to_s,
      "subject" => result.subject.qualified_name,
      "details" => result.details,
      "killers" => kills && kills.killed_by.map { |_file, name, _id| name },
      "ran" => kills && kills.ran.map { |_file, name, _id| name },
      "complete" => kills&.complete
    }
  end

  def mutations_for(subject, source)
    OPERATORS.flat_map do |name|
      Mutineer::MutatorRegistry.resolve([name]).first.new.mutations_for(subject, source)
    end
  end

  def token(source, mutation)
    source.byteslice(mutation.start_offset, mutation.end_offset - mutation.start_offset)
  end

  # Both assignments, as Rails' `config.encoding =` does. External alone does
  # not encode a new file. Must not leak into later tests: it changes how
  # every new IO is encoded, which is the bug's trigger.
  def run_with_rails_encodings
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      payload =
        begin
          Encoding.default_external = Encoding::UTF_8
          Encoding.default_internal = Encoding::UTF_8
          yield
        rescue StandardError => e
          { "raised" => "#{e.class}: #{e.message}", "trace" => e.backtrace&.first(12) }
        end
      writer.write(JSON.generate(payload))
      writer.close
      exit!(0)
    end
    writer.close
    raw = reader.read
    reader.close
    status = wait_child(pid, timeout: 60)
    assert_equal 0, status.exitstatus, raw
    report = JSON.parse(raw)
    flunk("#{report["raised"]}\n#{Array(report["trace"]).join("\n")}") if report.is_a?(Hash) && report["raised"]

    report
  end

  # Returns [verdict strings in request order, daemon stderr].
  def daemon_replies(codes)
    lib = File.expand_path("../lib", __dir__)
    fixtures = File.dirname(SOURCE)
    requests = codes.each_with_index.map do |code, id|
      {
        "id" => id, "worker" => 0, "timeout" => 30,
        "payload" => { "code" => code, "source_file" => SOURCE },
        "tests" => [MINITEST]
      }
    end
    stdin = [
      { "cmd" => "boot", "project_root" => fixtures, "boot" => BOOT, "framework" => "minitest",
        "source_dirs" => [fixtures] },
      *requests,
      { "cmd" => "quit" }
    ].map { |message| JSON.generate(message) }.join("\n") + "\n"
    script = "require \"mutineer/daemon_server\"; Mutineer::DaemonServer.run"
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script, stdin_data: stdin)
    assert status.success?, err
    lines = out.lines.map { |line| JSON.parse(line) }
    ready = lines.shift
    assert_equal true, ready["ready"], ready.inspect
    assert_equal (0...codes.size).to_a, lines.map { |line| line["id"] }

    [lines.map { |line| line["verdict"] }, err]
  end
end
