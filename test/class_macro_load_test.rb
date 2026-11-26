# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "minitest/mock"
require "open3"
require "rbconfig"
require "fileutils"
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

  # #493: a class macro that stores a lambda and a multi-line block. A class
  # that called the macro before the mutant keeps the original copies, so no
  # test runs a mutant inside them. The reach probe tells: a survivor in a
  # block whose call ran at load, that no test ran, is ran_at_load.
  LANGUAGE_SOURCES = %w[lib/language_record.rb lib/language_product.rb].freeze
  LANGUAGE_TEST = "test/language_product_test.rb"
  LANGUAGE_OPERATORS = %w[comparison statement_removal call_to_receiver].freeze

  # The five mutants inside the lambda and the block.
  LANGUAGE_BLOCK_MUTANTS = [
    "call_to_receiver value.strip",
    "comparison ==",
    "call_to_receiver record.language",
    "call_to_receiver record.language.downcase",
    "call_to_receiver record.errors"
  ].freeze

  # The two mutants of the macro's own statements, outside a block.
  LANGUAGE_STATEMENT_MUTANTS = [
    "statement_removal normalizers[:language] = ->(value) { value.strip }",
    "statement_removal limits[:language] = 35"
  ].freeze

  # initialize runs in every test, after the mutant. > to >= is a real survivor.
  LANGUAGE_INITIALIZE = {
    "comparison >" => "survived",
    "statement_removal @language = self.class.normalizers[:language].call(language)" => "killed",
    "statement_removal @errors = []" => "killed",
    "statement_removal self.class.checks.each { |check| check.call(self) }" => "killed",
    "call_to_receiver self.class.normalizers[:language].call(language)" => "killed",
    "call_to_receiver self.class.normalizers" => "killed",
    "call_to_receiver self.class.checks.each { |check| check.call(self) }" => "killed",
    "call_to_receiver check.call(self)" => "killed",
    "call_to_receiver @language.size" => "killed",
    "call_to_receiver self.class.limits" => "killed"
  }.freeze

  # The caller loaded before the mutant.
  LANGUAGE_STALE = (LANGUAGE_BLOCK_MUTANTS + LANGUAGE_STATEMENT_MUTANTS).to_h { |key| [key, "ran_at_load"] }
                                                                       .merge(LANGUAGE_INITIALIZE).freeze

  # #286: the ran_at_load mutants of LANGUAGE_STALE that survived their tests
  # first. No test is selected for `limits[:language] = 35`, so it never ran.
  LANGUAGE_TESTED = (LANGUAGE_BLOCK_MUTANTS + [LANGUAGE_STATEMENT_MUTANTS.first]).sort.freeze

  # The caller loads after the mutant, so the tests run the mutated copies.
  LANGUAGE_FRESH = (LANGUAGE_BLOCK_MUTANTS + LANGUAGE_STATEMENT_MUTANTS).to_h { |key| [key, "killed"] }
                                                                       .merge(LANGUAGE_INITIALIZE).freeze

  # Runs one fresh process and names each mutant by operator and source text.
  def run_rows(sources:, tests:, boot:, strategy:, operators:, root: ROOT, framework: "minitest", matrix: false)
    Dir.mktmpdir("mutineer-stored-block") do |cache|
      script = <<~RUBY
        require "mutineer"
        require "json"
        ENV.delete("CI")
        config = Mutineer::Config.new(sources: #{sources.inspect}, tests: #{tests.inspect},
                                      boot: #{boot.inspect}, strategy: #{strategy.inspect},
                                      operators: #{operators.inspect}, framework: #{framework.inspect},
                                      matrix: #{matrix.inspect},
                                      project_root: #{root.inspect}, cache_dir: #{cache.inspect}, jobs: 1)
        agg = Mutineer::Runner.execute(config).first
        rows = agg.results.map do |result|
          mutation = result.mutation
          text = File.read(result.subject.file)
          snippet = text.byteslice(mutation.start_offset, mutation.end_offset - mutation.start_offset)
          # R13 (#286): a ran_at_load result is tested exactly when it has a run
          # time. If a later change gives a run time to a result that never ran,
          # change this check, not the field.
          if result.ran_at_load? && result.tested_at_load? != !result.seconds.nil?
            raise "tested_at_load and seconds disagree: \#{mutation.operator} \#{snippet}"
          end
          ["\#{mutation.operator} \#{snippet}", result.status.to_s, result.kills&.killed_by, result.tested_at_load?]
        end
        $stdout.puts JSON.generate("rows" => rows, "score" => agg.mutation_score)
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script, chdir: root)
      assert status.success?, "run failed (#{strategy} boot=#{boot.inspect}): #{err}"
      doc = JSON.parse(out.lines.last)
      rows = doc["rows"]
      assert_equal rows.size, rows.map(&:first).uniq.size, "two mutants share a name"
      [rows.to_h { |key, verdict, _killed_by| [key, verdict] }, doc["score"],
       rows.to_h { |key, _verdict, killed_by| [key, killed_by] },
       rows.select { |row| row[3] }.map(&:first).sort]
    end
  end

  # AE1, the reported case: both files are sources, so redefine loads
  # LanguageProduct in the parent, before any mutant. Lazy boot does not help.
  def test_a_block_that_the_caller_stored_before_the_mutant_is_ran_at_load
    rows, score, _killed_by, tested = run_rows(sources: LANGUAGE_SOURCES, tests: [LANGUAGE_TEST],
                                               boot: "language_lazy_boot.rb", strategy: "redefine",
                                               operators: LANGUAGE_OPERATORS)
    assert_equal LANGUAGE_STALE, rows
    assert_in_delta 90.0, score, 0.001
    assert_equal LANGUAGE_TESTED, tested # AE3 (#286)
  end

  # AE2: the caller loads at boot, as under Rails eager load. Reload runs the
  # macro's file again. It does not run the caller's class body again.
  def test_eager_load_gives_the_same_verdicts_under_both_strategies
    %w[reload redefine].each do |strategy|
      rows, score, _killed_by, tested = run_rows(sources: ["lib/language_record.rb"], tests: [LANGUAGE_TEST],
                                                 boot: "language_eager_boot.rb", strategy: strategy,
                                                 operators: LANGUAGE_OPERATORS)
      assert_equal LANGUAGE_STALE, rows, strategy
      assert_in_delta 90.0, score, 0.001, strategy
      assert_equal LANGUAGE_TESTED, tested, strategy
    end
  end

  # AE3: only the macro's file is a source and the boot is lazy, so the caller
  # loads in the child, after the mutant. Each mutant keeps its real verdict.
  def test_a_caller_that_loads_after_the_mutant_keeps_real_verdicts
    %w[reload redefine].each do |strategy|
      rows, score = run_rows(sources: ["lib/language_record.rb"], tests: [LANGUAGE_TEST],
                             boot: "language_lazy_boot.rb", strategy: strategy, operators: LANGUAGE_OPERATORS)
      assert_equal LANGUAGE_FRESH, rows, strategy
      assert_in_delta 94.1, score, 0.001, strategy
    end
  end

  # AE3, the mechanism: the test that checks the stored block kills its mutant.
  def test_the_kill_of_a_fresh_block_names_the_test_that_ran_it
    rows, _score, killed_by = run_rows(sources: ["lib/language_record.rb"], tests: [LANGUAGE_TEST],
                                       boot: "language_lazy_boot.rb", strategy: "redefine",
                                       operators: LANGUAGE_OPERATORS, matrix: true)
    assert_equal "killed", rows["comparison =="]
    assert_equal [LANGUAGE_TEST], killed_by["comparison =="].map(&:first).uniq
    assert_equal %w[LanguageProductTest#test_rejects_a_long_value LanguageProductTest#test_rejects_upper_case],
                 killed_by["comparison =="].map { |row| row[1] }.sort
  end

  # The verdict step runs after the test runner returns, so it does not
  # depend on the framework. One RSpec run of the reported case proves it.
  def test_rspec_gives_the_same_verdicts_for_the_reported_case
    rows, score = run_rows(sources: LANGUAGE_SOURCES, tests: ["spec/language_product_spec.rb"],
                           boot: "language_lazy_boot.rb", strategy: "redefine", operators: LANGUAGE_OPERATORS,
                           framework: "rspec")
    assert_equal LANGUAGE_STALE, rows
    assert_in_delta 90.0, score, 0.001
  end

  # A limit of the rule (#588): boot calls apply([]) and so does the test. The
  # each line is covered and its block never runs. No test ran the mutant, so
  # it is ran_at_load. On 1.9.0 it was survived, which named the missing test.
  def test_a_block_that_no_test_runs_is_ran_at_load
    %w[reload redefine].each do |strategy|
      rows, score, _killed_by, tested = run_rows(sources: ["lib/apply_each.rb"],
                                                 tests: ["test/apply_each_empty_test.rb"], boot: "apply_boot.rb",
                                                 strategy: strategy, operators: %w[literal_mutation])
      assert_equal({ "literal_mutation \"original\"" => "ran_at_load" }, rows, strategy)
      assert_nil score, strategy
      assert_equal ["literal_mutation \"original\""], tested, strategy # AE4 (#286)
    end
  end

  # A limit of the rule (#588): the test stores a new copy of the block and
  # takes one branch. The mutant in that branch runs and is killed. The mutant
  # in the other branch does not run, so it is ran_at_load, not survived.
  def test_a_branch_of_a_stored_block_that_no_test_takes_is_ran_at_load
    with_project(
      "lib/flagged.rb" => <<~'RUBY',
        class Flagged
          def self.rules = (@rules ||= [])

          def self.flag_field
            rules << proc { |value| value ? "yes" : "no" }
          end
        end
      RUBY
      "boot.rb" => "require_relative \"lib/flagged\"\nFlagged.flag_field\n",
      "test/flagged_test.rb" => <<~'RUBY'
        require "minitest/autorun"

        class FlaggedTest < Minitest::Test
          def test_the_yes_branch
            Flagged.flag_field
            assert_equal "yes", Flagged.rules.last.call(true)
          end
        end
      RUBY
    ) do |root|
      %w[reload redefine].each do |strategy|
        rows, _score, _killed_by, tested = run_rows(sources: ["lib/flagged.rb"], tests: ["test/flagged_test.rb"],
                                                    boot: "boot.rb", strategy: strategy,
                                                    operators: %w[literal_mutation], root: root)
        assert_equal({ "literal_mutation \"yes\"" => "killed", "literal_mutation \"no\"" => "ran_at_load" },
                     rows, strategy)
        assert_equal ["literal_mutation \"no\""], tested, strategy # #286
      end
    end
  end

  # R4 for a def in a concern's hook block (#297). Boot includes the concern
  # and calls tags([]), so the each line is a load line. The test includes the
  # concern in a new class and runs the block with no check on its value. A
  # test ran the mutant, so it stays survived. The new class gets its def from
  # the reloaded file text, which has no probe, so the probe of the placed def
  # cannot speak for it.
  def test_a_block_in_a_hook_block_def_that_a_test_runs_stays_a_survivor
    stub = File.expand_path("fixtures/singleton/concern_stub.rb", __dir__)
    with_project(
      "lib/tagged.rb" => <<~'RUBY',
        module Tagged
          extend ActiveSupport::Concern

          included do
            def tags(xs)
              xs.each { |x| @kept = "original" }
            end

            attr_reader :kept
          end
        end
      RUBY
      "boot.rb" => <<~RUBY,
        require #{stub.inspect}
        require_relative "lib/tagged"
        class TaggedHost
          include Tagged
        end
        TaggedHost.new.tags([])
      RUBY
      "test/tagged_test.rb" => <<~'RUBY'
        require "minitest/autorun"

        class TaggedTest < Minitest::Test
          def test_a_new_class_runs_the_block
            host = Class.new { include Tagged }.new
            host.tags([1])
            assert host.kept
          end
        end
      RUBY
    ) do |root|
      rows, score = run_rows(sources: ["lib/tagged.rb"], tests: ["test/tagged_test.rb"], boot: "boot.rb",
                             strategy: "reload", operators: %w[literal_mutation], root: root)
      assert_equal({ "literal_mutation \"original\"" => "survived" }, rows)
      assert_in_delta 0.0, score, 0.001
    end
  end

  # AE5 and AE6: the daemon classifies in {DaemonBackend.job_result} with the
  # same three steps as in-process reload. A booted daemon needs the app's
  # Gemfile, so this drives that method with the fixture's jobs and a client
  # that answers survived. The client stands in for the daemon child: it
  # writes the sentinel when a test ran the mutated expression.
  def test_the_daemon_moves_a_block_survivor_only_when_the_probe_did_not_fire
    source = File.join(ROOT, "lib/language_record.rb")
    config = Mutineer::Config.new(sources: [source], tests: [File.join(ROOT, LANGUAGE_TEST)],
                                  project_root: ROOT, operators: LANGUAGE_OPERATORS, framework: "minitest")
    jobs, _ignored, source_map, = Mutineer::JobPlan.collect_jobs(config, Mutineer::MutatorRegistry.resolve(LANGUAGE_OPERATORS))
    text = source_map[jobs.first[0].file]
    rel = Mutineer::ProjectPath.relative(jobs.first[0].file, ROOT)
    covered = (1..text.lines.size).to_h { |line| ["#{rel}:#{line}", [LANGUAGE_TEST]] }
    calls = ["->(value)", "limits[:language] = 35", "checks << proc"].map do |snippet|
      "#{rel}:#{text.lines.index { |row| row.include?(snippet) } + 1}"
    end
    macro = LANGUAGE_BLOCK_MUTANTS + LANGUAGE_STATEMENT_MUTANTS
    block = ->(verdict) { LANGUAGE_BLOCK_MUTANTS.to_h { |key| [key, verdict] } }
    statements = ->(verdict) { LANGUAGE_STATEMENT_MUTANTS.to_h { |key| [key, verdict] } }

    run = lambda do |load_lines:, fires:|
      map = Mutineer::CoverageMap.from_data(map: covered, failed_test_files: [], project_root: ROOT,
                                            load_lines: load_lines)
      probed = []
      client = Object.new
      client.define_singleton_method(:last_cause) { nil }
      client.define_singleton_method(:request) do |payload:, **|
        probed << payload["code"] if payload["reach_path"]
        File.write(payload["reach_path"], "1") if fires && payload["reach_path"]
        "survived"
      end
      tested = []
      rows = jobs.to_h do |job|
        result = Mutineer::DaemonBackend.send(:job_result, job, 0, client, 0, config, map, [], source_map)
        mutation = result.mutation
        snippet = text.byteslice(mutation.start_offset, mutation.end_offset - mutation.start_offset)
        tested << "#{mutation.operator} #{snippet}" if result.tested_at_load?
        ["#{mutation.operator} #{snippet}", result.status.to_s]
      end
      [rows.slice(*macro), probed, (tested & macro).sort]
    end

    # The probe fired: a test ran the mutated block, so the mutant counts.
    rows, probed, tested = run.call(load_lines: calls, fires: true)
    assert_equal block.call("survived").merge(statements.call("ran_at_load")), rows
    # #286: the two statement mutants survived their tests, then load_verdict moved them.
    assert_equal LANGUAGE_STATEMENT_MUTANTS.sort, tested
    # Only the five block mutants carry the probe. A mutant outside a block
    # on a load line is ran_at_load from load_verdict, as before.
    assert_equal 5, probed.size
    assert(probed.all? { |code| code.include?("mutineer_r") })

    # The probe did not fire: the tests ran a copy that the load stored.
    rows, _probed, tested = run.call(load_lines: calls, fires: false)
    assert_equal block.call("ran_at_load").merge(statements.call("ran_at_load")), rows
    # #286: the map covers every line and the client answers survived, so each one is tested.
    assert_equal macro.sort, tested

    # No call ran at load: no mutant carries the probe, and each one counts.
    rows, probed = run.call(load_lines: [], fires: false)
    assert_equal macro.to_h { |key| [key, "survived"] }, rows
    assert_empty probed

    # AE5: the wrap fails, so the sent text has no probe. No evidence, no change.
    rows, probed = Mutineer::ReachProbe.stub(:wrap, nil) { run.call(load_lines: calls, fires: false) }
    assert_equal block.call("survived").merge(statements.call("ran_at_load")), rows
    assert_equal 5, probed.size
    assert(probed.none? { |code| code.include?("mutineer_r") })
  end

  # Writes a project of `files` (relative path to text) and yields its real
  # root. The coverage map names files by their real path.
  def with_project(files)
    Dir.mktmpdir("mutineer-stored-block-project") do |dir|
      root = File.realpath(dir)
      files.each do |path, text|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, text)
      end
      yield root
    end
  end
end
