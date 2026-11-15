# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# #435: mutants of a class macro that define_method's on one line. Eager load
# runs the caller's class body before the mutant, so the generated method
# keeps the original block. The call's mutants were ran_at_load and the
# block's literals survived. Both are ran_at_load now. Without that load the
# caller runs after the mutant and the literals are killed. CI is not the
# signal. Re-running the caller so the eager mutants can be killed is #389.
class ClassMacroLoadTest < Minitest::Test
  ROOT = File.expand_path("fixtures/load_time", __dir__)
  LIB = File.expand_path("../lib", __dir__)
  SOURCE = "lib/greetable.rb"
  TEST_FILE = "test/greetable_test.rb"
  OPERATORS = %w[return_nil literal_mutation collection_method call_to_receiver].freeze

  # The caller loads after the mutant, so greets runs mutated. each → map
  # still defines the method, so that one survives.
  LAZY = {
    "return_nil" => "killed",
    "literal_mutation:greet_" => "killed",
    "literal_mutation:Hello, " => "killed",
    "collection_method" => "survived",
    "call_to_receiver" => "killed"
  }.freeze

  # The caller loaded at boot. Every mutant of the line is ran_at_load,
  # including the two literals that share the line with the call.
  EAGER = {
    "return_nil" => "ran_at_load",
    "literal_mutation:greet_" => "ran_at_load",
    "literal_mutation:Hello, " => "ran_at_load",
    "collection_method" => "ran_at_load",
    "call_to_receiver" => "ran_at_load"
  }.freeze

  # Runs one fresh process. Boot coverage and a required source only work in
  # a process that has not loaded the fixture.
  def run_macro(strategy:, boot:, ci:, source: SOURCE, test: TEST_FILE, operators: OPERATORS)
    Dir.mktmpdir("mutineer-class-macro") do |cache|
      script = <<~RUBY
        require "mutineer"
        require "json"
        #{ci ? 'ENV["CI"] = "true"' : "ENV.delete(\"CI\")"}
        config = Mutineer::Config.new(sources: [#{source.inspect}], tests: [#{test.inspect}],
                                      boot: #{boot.inspect}, strategy: #{strategy.inspect},
                                      operators: #{operators.inspect},
                                      project_root: #{ROOT.inspect}, cache_dir: #{cache.inspect}, jobs: 1)
        agg = Mutineer::Runner.execute(config).first
        source = File.read(config.sources.first)
        rows = agg.results.map do |result|
          mutation = result.mutation
          snippet = source.byteslice(mutation.start_offset, mutation.end_offset - mutation.start_offset)
          key = mutation.operator.to_s
          key = "\#{key}:\#{snippet}" if key == "literal_mutation"
          [key, result.status.to_s]
        end
        $stdout.puts JSON.generate("rows" => rows, "score" => agg.mutation_score,
                                   "ci" => ENV["CI"])
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script, chdir: ROOT)
      assert status.success?, "run failed (#{strategy} boot=#{boot.inspect} ci=#{ci}): #{err}"
      doc = JSON.parse(out.lines.last)
      if ci
        assert_equal "true", doc["ci"]
      else
        assert_nil doc["ci"]
      end
      [doc["rows"].to_h, doc["score"]]
    end
  end

  def test_without_eager_load_the_literals_are_killed_and_ci_does_not_matter
    [false, true].each do |ci|
      [nil, "greetable_boot.rb"].each do |boot|
        %w[reload redefine].each do |strategy|
          rows, score = run_macro(strategy: strategy, boot: boot, ci: ci)
          assert_equal LAZY, rows, "#{strategy} boot=#{boot.inspect} CI=#{ci}"
          assert_in_delta 80.0, score, 0.001, "#{strategy} boot=#{boot.inspect} CI=#{ci}"
        end
      end
    end
  end

  def test_eager_load_classifies_the_shared_line_mutants_as_ran_at_load
    [false, true].each do |ci|
      %w[reload redefine].each do |strategy|
        rows, score = run_macro(strategy: strategy, boot: "greeter_boot.rb", ci: ci)
        assert_equal EAGER, rows, "#{strategy} CI=#{ci}"
        assert_nil score, "#{strategy} CI=#{ci}: every mutant is excluded, so the score is nil, not 0.0"
      end
    end
  end

  # Boot calls apply([]) so the each line runs and the block does not. The test
  # calls apply([1]) and does not check the string, so the mutant runs and
  # survives. It is not ran_at_load: the shared line is not a define_method call.
  def test_an_each_block_on_a_load_line_stays_a_survivor
    %w[reload redefine].each do |strategy|
      rows, score = run_macro(strategy: strategy, boot: "apply_boot.rb", ci: false,
                              source: "lib/apply_each.rb", test: "test/apply_each_test.rb",
                              operators: %w[literal_mutation])
      assert_equal ["survived"], rows.values.uniq, strategy
      assert_equal 1, rows.size, strategy
      assert_in_delta 0.0, score, 0.001, strategy
    end
  end

  # The daemon reloads the file and classifies in {DaemonBackend.job_result},
  # the same {JobPlan.load_verdict} as in-process reload. It has no redefine
  # path. A booted daemon needs the app's Gemfile, so this drives that method
  # with the fixture's jobs. The child reports every mutant survived: the load
  # line of `names.each` turns each one into ran_at_load, and without that line
  # they stay survived. The in-process runs above are what kill the literals
  # when the caller loads after the mutant.
  def test_the_daemon_classifies_a_shared_load_line_like_in_process_reload
    source = File.join(ROOT, SOURCE)
    config = Mutineer::Config.new(sources: [source], tests: [File.join(ROOT, TEST_FILE)],
                                  project_root: ROOT, operators: OPERATORS, framework: "minitest")
    ops = Mutineer::MutatorRegistry.resolve(OPERATORS)
    jobs, _ignored, source_map, = Mutineer::JobPlan.collect_jobs(config, ops)
    text = source_map[jobs.first[0].file]
    line = text.lines.index { |row| row.include?("names.each") } + 1
    rel = "#{Mutineer::ProjectPath.relative(jobs.first[0].file, ROOT)}:#{line}"
    client = Object.new
    def client.request(...) = "survived"
    def client.last_cause = nil
    survived = LAZY.keys.to_h { |key| [key, "survived"] }

    [true, false].each do |loaded|
      map = Mutineer::CoverageMap.from_data(
        map: { rel => ["test/greetable_test.rb"] },
        failed_test_files: [], project_root: ROOT,
        load_lines: (loaded ? [rel] : [])
      )
      rows = jobs.map.with_index do |job, index|
        result = Mutineer::DaemonBackend.send(:job_result, job, index, client, 0, config, map, [], source_map)
        mutation = result.mutation
        snippet = text.byteslice(mutation.start_offset, mutation.end_offset - mutation.start_offset)
        key = mutation.operator.to_s
        key = "#{key}:#{snippet}" if key == "literal_mutation"
        [key, result.status.to_s]
      end
      assert_equal(loaded ? EAGER : survived, rows.to_h, "load line #{loaded}")
    end
  end
end
