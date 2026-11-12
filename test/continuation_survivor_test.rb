# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_server"
require "tmpdir"

# #345: a survivor on a continuation line used to be no_coverage, which left
# it out of the score. The reaching suite runs the expression and still
# passes, so the mutant is survived and the score is 0. The missing suite
# runs only the line Ruby counts, so the same mutant stays no_coverage and
# the score stays nil. Both strategies, and the daemon's payload, share that
# rule.
class ContinuationSurvivorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SOURCE = File.expand_path("fixtures/continuation_reach.rb", __dir__)
  REACH = File.expand_path("fixtures/continuation_reach_test.rb", __dir__)
  MISS = File.expand_path("fixtures/continuation_reach_miss_test.rb", __dir__)
  LOAD_SOURCE = File.expand_path("fixtures/continuation_load.rb", __dir__)
  LOAD_REACH = File.expand_path("fixtures/continuation_load_test.rb", __dir__)
  LOAD_MISS = File.expand_path("fixtures/continuation_load_miss_test.rb", __dir__)
  # One mutant per method: `>` becomes `>=`, and the trailing `+` becomes `-`.
  EXPECTED = {
    adult?: [:comparison, ">="],
    labels: [:comparison, ">="],
    widths: [:comparison, ">="],
    tally: [:comparison, ">="],
    note: [:comparison, ">="],
    sums: [:arithmetic, "-"]
  }.freeze

  def test_a_reached_continuation_survivor_counts_and_an_unreached_one_does_not
    %w[reload redefine].each do |strategy|
      reached = run_suite(REACH, strategy)
      missed = run_suite(MISS, strategy)

      assert_equal EXPECTED.keys.sort, reached.results.map { |result| result.subject.name }.sort, strategy
      assert_equal rows(reached, :survived), EXPECTED, "#{strategy} reaching"
      assert_equal 0.0, reached.mutation_score, strategy
      assert_equal EXPECTED.size, reached.covered_count, strategy
      assert_equal 0, reached.no_coverage_count, strategy

      assert_equal rows(missed, :no_coverage), EXPECTED, "#{strategy} missing"
      assert_nil missed.mutation_score, strategy
      assert_equal 0, missed.covered_count, strategy
      assert_equal EXPECTED.size, missed.no_coverage_count, strategy
    end
  end

  # The class body calls the continuation. That load is cleared before the
  # tests. A test that never enters the expression stays no_coverage. A test
  # that enters it during the test is survived.
  def test_a_load_time_call_does_not_count_as_the_test_reaching_the_expression
    %w[reload redefine].each do |strategy|
      reached = run_suite(LOAD_REACH, strategy, [LOAD_SOURCE], %w[comparison])
      missed = run_suite(LOAD_MISS, strategy, [LOAD_SOURCE], %w[comparison])

      assert_equal [:survived], reached.results.map(&:status), strategy
      assert_equal 0.0, reached.mutation_score, strategy
      assert_equal [:no_coverage], missed.results.map(&:status), strategy
      assert_nil missed.mutation_score, strategy
      assert_equal 1, missed.no_coverage_count, strategy
    end
  end

  # The daemon child clears the sentinel after load. A test that does not
  # enter the expression leaves it empty; a test that does writes it again.
  def test_the_daemon_forgets_a_load_time_call_before_its_tests
    source = File.read(LOAD_SOURCE)
    subject = Mutineer::Project.discover([LOAD_SOURCE]).find { |item| item.name == :adult? }
    mutation = Mutineer::Mutators::Comparison.new.mutations_for(subject, source).fetch(0)
    sentinel = Mutineer::ReachProbe.sentinel
    code = Mutineer::ReachProbe.wrap_mutation(mutation.apply(source), mutation, sentinel.path)
    daemon = Mutineer::DaemonServer
    saved = %i[@errio @worker_db @slot_ready @source_dirs @framework @shared_databases].to_h do |name|
      [name, daemon.instance_variable_get(name)]
    end
    Dir.mktmpdir("mutineer-load-daemon") do |dir|
      err = File.open(File.join(dir, "err"), "w")
      err.sync = true
      daemon.instance_variable_set(:@errio, err)
      daemon.instance_variable_set(:@worker_db, nil)
      daemon.instance_variable_set(:@slot_ready, {})
      daemon.instance_variable_set(:@source_dirs, [dir])
      daemon.instance_variable_set(:@framework, "minitest")
      daemon.instance_variable_set(:@shared_databases, [])
      miss = File.join(dir, "miss_test.rb")
      reach = File.join(dir, "reach_test.rb")
      File.write(miss, "require \"minitest/autorun\"\nclass ContinuationLoadMiss < Minitest::Test\n" \
                       "def test_false; refute ContinuationLoad.adult?(false); end\nend\n")
      File.write(reach, "require \"minitest/autorun\"\nclass ContinuationLoadReach < Minitest::Test\n" \
                        "def test_true; assert ContinuationLoad.adult?(true); end\nend\n")
      payload = { "code" => code, "source_file" => LOAD_SOURCE, "reach_path" => sentinel.path }

      missed = daemon.send(:run_mutant, "id" => 1, "worker" => 0, "timeout" => 30, "payload" => payload,
                                        "tests" => [miss])
      miss_reached = Mutineer::ReachProbe.reached?(sentinel)
      reached = daemon.send(:run_mutant, "id" => 2, "worker" => 0, "timeout" => 30, "payload" => payload,
                                         "tests" => [reach])

      assert_equal "survived", missed["verdict"], File.read(err.path)
      refute miss_reached, "a load-time call was counted as a test"
      assert_equal "survived", reached["verdict"], File.read(err.path)
      assert Mutineer::ReachProbe.reached?(sentinel), "a test that ran the expression left no sentinel"
    end
  ensure
    saved&.each { |name, value| daemon.instance_variable_set(name, value) }
    Mutineer::ReachProbe.close_sentinel(sentinel) if defined?(sentinel) && sentinel
    Object.send(:remove_const, :ContinuationLoad) if defined?(ContinuationLoad)
  end

  # The daemon child loads the probed source. Executing that source is what
  # writes the sentinel; job_result reads the same file the in-process child
  # writes.
  def test_the_daemon_payload_scores_a_reached_survivor_and_an_unreached_one
    source = File.read(SOURCE)
    subject = Mutineer::Project.discover([SOURCE]).find { |item| item.name == :adult? }
    mutation = Mutineer::Mutators::Comparison.new.mutations_for(subject, source).fetch(0)
    config = Mutineer::Config.new(sources: [SOURCE], tests: [REACH], project_root: ROOT, framework: "minitest")
    coverage = Mutineer::CoverageMap.from_data(map: { "x:1" => ["t.rb"] }, failed_test_files: [],
                                                project_root: ROOT)
    job = [subject, mutation, "adult"]

    reached, code = daemon_result(job, config, coverage, source, call: "ContinuationReach.adult?(20, true)")
    missed, = daemon_result(job, config, coverage, source, call: "ContinuationReach.adult?(20, false)")
    killed, = daemon_result(job, config, coverage, source, call: "ContinuationReach.adult?(20, true)",
                            verdict: "killed")

    assert_equal :survived, reached.status
    assert_includes code, "::File.write"
    assert_equal :no_coverage, missed.status
    assert_equal :killed, killed.status
    assert_equal :comparison, reached.mutation.operator
    assert_equal ">=", reached.mutation.replacement
  ensure
    Object.send(:remove_const, :ContinuationReach) if defined?(ContinuationReach)
  end

  def rows(aggregate, status)
    aggregate.results.to_h do |result|
      assert_equal status, result.status, "#{result.subject.name} #{result.mutation.replacement} #{result.details}"
      [result.subject.name, [result.mutation.operator, result.mutation.replacement]]
    end
  end

  def run_suite(test, strategy, sources = [SOURCE], operators = %w[comparison arithmetic])
    config = Mutineer::Config.new(sources: sources, tests: [test], operators: operators,
                                  cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT,
                                  strategy: strategy)
    aggregate, = Mutineer::Runner.execute(config)
    aggregate
  end

  def daemon_result(job, config, coverage, source, call:, verdict: "survived")
    code = nil
    client = Object.new
    client.define_singleton_method(:request) do |payload:, **|
      code = payload.fetch("code")
      file = Tempfile.new(["daemon-reach-", ".rb"])
      file.write("#{code}\n#{call}\n")
      file.close
      Object.send(:remove_const, :ContinuationReach) if defined?(ContinuationReach)
      load file.path
      verdict
    end
    client.define_singleton_method(:last_cause) { nil }
    result = Mutineer::JobPlan.stub(:coverage_selection, [:maybe, [REACH]]) do
      Mutineer::DaemonBackend.send(:job_result, job, 0, client, 0, config, coverage, [REACH], { SOURCE => source })
    end
    [result, code]
  end
end
