# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Acceptance gates that exercise the full Phase-B pipeline: --jobs determinism
# (R4) and 7a/7b verdict parity (R19/U6).
class ParallelStrategyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_brutus(strategy: "7a", jobs: nil)
    config = Brutus::Config.new(
      sources: ["test/fixtures/calculator.rb"],
      tests: ["test/fixtures/calculator_weak_test.rb"],
      cache_dir: Dir.mktmpdir("brutus-cache"), project_root: ROOT,
      strategy: strategy, jobs: jobs
    )
    Brutus::Runner.execute(config).first
  end

  def survivor_keys(agg)
    agg.surviving_mutants.map { |r| [r.subject.name.to_s, r.mutation.replacement] }.sort
  end

  def test_jobs_one_matches_jobs_four
    serial   = run_brutus(jobs: 1)
    parallel = run_brutus(jobs: 4)
    assert_equal serial.mutation_score, parallel.mutation_score
    assert_equal serial.killed_count, parallel.killed_count
    assert_equal survivor_keys(serial), survivor_keys(parallel)
  end

  def test_strategy_7b_matches_7a
    a = run_brutus(strategy: "7a", jobs: 1)
    b = run_brutus(strategy: "7b", jobs: 1)
    assert_equal a.mutation_score, b.mutation_score
    assert_equal survivor_keys(a), survivor_keys(b)
  end

  def run_namespaced(strategy:)
    config = Brutus::Config.new(
      sources: ["test/fixtures/namespaced.rb"],
      tests: ["test/fixtures/namespaced_test.rb"],
      cache_dir: Dir.mktmpdir("brutus-cache"), project_root: ROOT,
      strategy: strategy, jobs: 1
    )
    Brutus::Runner.execute(config).first
  end

  # C2 proof: a MULTI-STATEMENT, NAMESPACED method run end-to-end under BOTH
  # strategies must yield IDENTICAL survivor sets. The surviving mutation
  # (`base * RATE` -> `/`) references an UNQUALIFIED enclosing-namespace constant,
  # which the old 7b turned into a NameError (a different verdict). It also proves
  # statement_removal generates a mutation here (the body has >=2 statements).
  def test_namespaced_multistatement_7a_equals_7b
    a = run_namespaced(strategy: "7a")
    b = run_namespaced(strategy: "7b")

    assert_equal survivor_keys(a), survivor_keys(b), "7a and 7b survivor sets must match"
    assert_equal a.killed_count, b.killed_count
    assert_equal a.errored_count, b.errored_count
    assert_equal [["total", "/"]], survivor_keys(a), "the RATE-referencing no-op mutation survives"
    assert_equal 0, a.errored_count, "no spurious NameError under 7b (constant resolves)"

    removals = a.results.count { |r| r.mutation&.operator == :statement_removal }
    assert_operator removals, :>=, 1, "statement_removal must run on the multi-statement body"
  end

  # apply_surgical mutates a live constant; run it in a child so the parent
  # process is left untouched.
  def test_apply_surgical_instance_method
    assert_equal "9", surgical_result(
      "class S7bInst\n  def val\n    1\n  end\nend\n",
      namespace: ["S7bInst"], singleton: false,
      token: "1", replacement: "9", call: "S7bInst.new.val"
    )
  end

  def test_apply_surgical_singleton_method
    assert_equal "9", surgical_result(
      "module S7bSing\n  def self.val\n    1\n  end\nend\n",
      namespace: ["S7bSing"], singleton: true,
      token: "1", replacement: "9", call: "S7bSing.val"
    )
  end

  # C1 for apply_surgical: a multibyte char before the def shifts byte offset off
  # char index. Byte-correct surgical splicing must still hit the right token.
  def test_apply_surgical_byte_correct_with_multibyte_prefix
    src = "# café\nclass S7bMB\n  def val\n    1\n  end\nend\n"
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      eval(src, TOPLEVEL_BINDING) # rubocop:disable Security/Eval
      def_node = Brutus::Parser.parse_string(src).value.statements.body.first.body.body.first
      subject = Brutus::Subject.new(file: "x.rb", namespace: ["S7bMB"],
                                    name: def_node.name, singleton: false, def_node: def_node)
      off = src.byteindex("1")
      mutation = Brutus::Mutation.new(start_offset: off, end_offset: off + 1,
                                      replacement: "9", operator: :literal_mutation)
      Brutus::Isolation.apply_surgical(mutation, subject, src)
      wr.write(eval("S7bMB.new.val", TOPLEVEL_BINDING).to_s) # rubocop:disable Security/Eval
      wr.close
      exit!(0)
    end
    wr.close
    out = rd.read
    rd.close
    Process.wait(pid)
    assert_equal "9", out
  end

  private

  # Defines the source in a forked child, applies the surgical mutation, and
  # returns the post-mutation value of `call` as a string.
  def surgical_result(src, namespace:, singleton:, token:, replacement:, call:)
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      eval(src, TOPLEVEL_BINDING) # rubocop:disable Security/Eval
      def_node = Brutus::Parser.parse_string(src).value.statements.body.first.body.body.first
      subject = Brutus::Subject.new(file: "x.rb", namespace: namespace,
                                    name: def_node.name, singleton: singleton, def_node: def_node)
      off = src.index(token)
      mutation = Brutus::Mutation.new(start_offset: off, end_offset: off + token.length,
                                      replacement: replacement, operator: :literal_mutation)
      Brutus::Isolation.apply_surgical(mutation, subject, src)
      wr.write(eval(call, TOPLEVEL_BINDING).to_s) # rubocop:disable Security/Eval
      wr.close
      exit!(0)
    end
    wr.close
    out = rd.read
    rd.close
    Process.wait(pid)
    out
  end
end
