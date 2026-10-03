# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# End-to-end: drive Runner.execute (standalone mode, real RSpec coverage Phase A
# + per-mutant runs) with framework: "rspec". A strong spec kills every mutant;
# a weak spec leaves a survivor — the RSpec mirror of the Minitest oracle.
class RSpecIntegrationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_mutineer(tests:, sources: ["test/fixtures/rspec/calculator.rb"], matrix: false, operators: ["arithmetic"])
    config = Mutineer::Config.new(
      sources: sources, tests: tests, matrix: matrix,
      framework: "rspec", operators: operators,
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT
    )
    aggregate, = Mutineer::Runner.execute(config)
    aggregate
  end

  def test_strong_spec_kills_all_mutants
    result = run_mutineer(tests: ["test/fixtures/rspec/calculator_strong_spec.rb"])
    assert_equal 0, result.survived_count, "strong spec should kill every mutant"
    assert_equal 2, result.killed_count, "expected +->- and *->/ killed"
    assert_equal 100.0, result.mutation_score
  end

  def test_weak_spec_leaves_survivor
    result = run_mutineer(tests: ["test/fixtures/rspec/calculator_weak_spec.rb"])
    assert_equal 1, result.survived_count, "weak spec should leave the add mutant alive"
    survivor = result.surviving_mutants.first
    assert_equal "add", survivor.subject.name.to_s
    assert_equal :arithmetic, survivor.mutation.operator
  end

  # A spec that reopens $stdout (to_stdout_from_any_process) must see the same
  # verdicts as the plain weak spec: no "not green" abort, no false kills.
  def test_spec_that_reopens_stdout_scores_like_weak_spec
    result = run_mutineer(tests: ["test/fixtures/rspec/calculator_subprocess_io_spec.rb"])
    assert_equal 1, result.survived_count
    assert_equal 1, result.killed_count
    assert_equal "add", result.surviving_mutants.first.subject.name.to_s
  end

  # A spec file that leaves $stdout/$stderr as StringIOs must not break the
  # silencing that the reopen fix added.
  def test_spec_that_swaps_stdout_for_a_stringio_scores_like_weak_spec
    result = run_mutineer(tests: ["test/fixtures/rspec/calculator_stdout_swap_spec.rb"])
    assert_equal 1, result.survived_count
    assert_equal 1, result.killed_count
    assert_equal "add", result.surviving_mutants.first.subject.name.to_s
  end

  # A spec file or a source file that prints at load time must not corrupt the
  # coverage result that the capture subprocess sends back, so no mutant
  # becomes unscoreable. The capture script loads sources before RSpec runs.
  def test_spec_that_prints_at_load_time_scores_like_weak_spec
    result = nil
    # The parent also requires each source, so the banner prints there once.
    capture_io do
      result = run_mutineer(sources: ["test/fixtures/rspec/calculator.rb", "test/fixtures/rspec/load_time_banner.rb"],
                            tests: ["test/fixtures/rspec/calculator_load_time_puts_spec.rb"])
    end
    assert_equal 1, result.survived_count
    assert_equal 1, result.killed_count
    assert_equal "add", result.surviving_mutants.first.subject.name.to_s
  end

  # #96: RSpec assertion failures on the unmutated suite abort before scoring.
  def test_failing_spec_aborts_before_scoring
    Dir.mktmpdir("mutineer-rspec-clean") do |dir|
      File.write(File.join(dir, "calc.rb"), "class AuditRSpecCalc\n  def add(a, b)\n    a + b\n  end\nend\n")
      File.write(File.join(dir, "calc_spec.rb"), <<~RUBY)
        require_relative "calc"
        RSpec.describe AuditRSpecCalc do
          it "adds" do
            expect(described_class.new.add(2, 3)).not_to be_nil
          end
          it "fails unrelated" do
            expect(1).to eq(2)
          end
        end
      RUBY
      config = Mutineer::Config.new(
        sources: ["calc.rb"], tests: ["calc_spec.rb"],
        framework: "rspec", operators: ["arithmetic"],
        cache_dir: File.join(dir, "cache"), project_root: dir
      )
      err = nil
      _, stderr = capture_subprocess_io { err = assert_raises(Mutineer::SmokeCheckError) { Mutineer::Runner.execute(config) } }
      assert_match(/unmutated suite is not green/, err.message)
      assert_match(/fails unrelated/, stderr)
    end
  end

  # The RSpec mirror of the kill-matrix oracle: the weak "adds" example kills
  # nothing, both "multiplies" examples kill the multiply mutant, and only the
  # strong "adds" kills the add mutant.
  def test_kill_matrix_names_blind_and_redundant_examples
    weak = "test/fixtures/rspec/calculator_weak_spec.rb"
    strong = "test/fixtures/rspec/calculator_strong_spec.rb"
    result = run_mutineer(tests: [weak, strong], matrix: true)
    matrix = Mutineer::KillMatrix.new(result.results)

    assert_equal 2, result.killed_count
    assert_predicate matrix, :complete?
    assert_equal [[weak, "RSpecCalculator adds"]], matrix.blind.map { |file, name, _id| [file, name] }
    assert_equal [[strong, "RSpecCalculator multiplies"], [weak, "RSpecCalculator multiplies"]],
                 matrix.redundant.map { |file, name, _id| [file, name] }
  end


  def names(tests) = tests.map { |_file, name, _id| name }
  def scoped_id(test) = test.last[/\[[\d:]+\]\z/]

  # Two examples share the description "checks", and one shared group is
  # included twice. Keyed on the example id, each is its own test: the first
  # "checks" is blind, and the second is the only killer of `>` -> `>=`.
  def test_kill_matrix_tells_apart_examples_that_share_a_description
    result = run_mutineer(sources: ["test/fixtures/rspec/matrix_calc.rb"],
                          tests: ["test/fixtures/rspec/matrix_calc_spec.rb"],
                          operators: %w[arithmetic comparison], matrix: true)
    km = Mutineer::KillMatrix.new(result.results)

    assert_predicate km, :complete?
    assert_equal 8, km.tests.size
    assert_equal ["MatrixCalc dup checks"], names(km.blind)
    assert_equal "[1:4:1]", scoped_id(km.blind.first)
    pos = result.results.find { |r| r.subject.name == :pos? && r.mutation.replacement == ">=" }
    assert_equal ["[1:4:2]"], pos.kills.killed_by.map { |t| scoped_id(t) }
    assert_equal ["MatrixCalc adds again", "MatrixCalc adds first", "MatrixCalc aggregates",
                  "MatrixCalc behaves like a matrix adder adds via shared",
                  "MatrixCalc behaves like a matrix adder adds via shared"], names(km.redundant)
  end

  # A parameterized shared group, defined in another file, included twice in
  # one group: the two inclusions share a full description. A before(:context)
  # that raises under a mutant fails the examples of its group.
  def test_kill_matrix_tells_apart_parameterized_shared_examples
    result = run_mutineer(sources: ["test/fixtures/rspec/matrix_calc.rb"],
                          tests: ["test/fixtures/rspec/matrix_params_spec.rb"], matrix: true)
    km = Mutineer::KillMatrix.new(result.results)
    shared = "test/fixtures/rspec/matrix_shared.rb"

    adds = km.tests.select { |file, _name, _id| file == shared }
    assert_equal ["MatrixCalc behaves like matrix adds adds correctly"] * 2, names(adds)
    assert_equal ["[1:1:1]"], km.blind.map { |t| scoped_id(t) }
    assert_equal [shared], km.blind.map(&:first)
    mul = result.results.find { |r| r.subject.name == :mul }
    assert_equal ["MatrixCalc multiplies", "MatrixCalc with a before(:context) that raises under a mutant inner one"],
                 names(mul.kills.killed_by)
  end

  # The suite's after(:suite) hook exits 0, which plain RSpec runs even after
  # a failed example, so the run without --matrix scores the mutant survived.
  def test_matrix_keeps_the_verdict_of_a_suite_hook_that_exits
    args = { sources: ["test/fixtures/rspec/matrix_calc.rb"], operators: ["comparison"],
             tests: ["test/fixtures/rspec/matrix_cleanup_spec.rb"] }
    plain = run_mutineer(**args)
    matrix = run_mutineer(**args, matrix: true)

    assert_equal plain.results.to_h { |r| [r.id, r.status] }, matrix.results.to_h { |r| [r.id, r.status] }
    pos = matrix.results.find { |r| r.subject.name == :pos? && r.mutation.replacement == ">=" }
    assert_predicate pos, :survived?
    refute pos.kills.complete
  end

  # An example without a description is worded from its matcher, so its name
  # changes with the mutant. Its example id does not, and it is one test.
  def test_kill_matrix_keeps_one_test_for_an_example_whose_description_changes
    result = run_mutineer(sources: ["test/fixtures/rspec/matrix_calc.rb"], operators: ["arithmetic"],
                          tests: ["test/fixtures/rspec/matrix_generated_spec.rb"], matrix: true)
    km = Mutineer::KillMatrix.new(result.results)

    assert_equal 2, km.tests.size
    assert_empty km.blind
  end

end
