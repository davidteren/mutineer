# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# End-to-end: drive Runner.execute (standalone mode, real RSpec coverage Phase A
# + per-mutant runs) with framework: "rspec". A strong spec kills every mutant;
# a weak spec leaves a survivor — the RSpec mirror of the Minitest oracle.
class RSpecIntegrationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_mutineer(tests:, sources: ["test/fixtures/rspec/calculator.rb"])
    config = Mutineer::Config.new(
      sources: sources, tests: tests,
      framework: "rspec", operators: ["arithmetic"],
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
      err = assert_raises(Mutineer::SmokeCheckError) { Mutineer::Runner.execute(config) }
      assert_match(/unmutated suite is not green/, err.message)
    end
  end
end
