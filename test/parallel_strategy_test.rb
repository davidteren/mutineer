# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Acceptance gates that exercise the full Phase-B pipeline: --jobs determinism
# (R4) and 7a/7b verdict parity (R19/U6).
class ParallelStrategyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_mutineer(strategy: "reload", jobs: nil)
    config = Mutineer::Config.new(
      sources: ["test/fixtures/calculator.rb"],
      tests: ["test/fixtures/calculator_weak_test.rb"],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT,
      strategy: strategy, jobs: jobs
    )
    Mutineer::Runner.execute(config).first
  end

  def survivor_keys(agg)
    agg.surviving_mutants.map { |r| [r.subject.name.to_s, r.mutation.replacement] }.sort
  end

  def test_jobs_one_matches_jobs_four
    serial   = run_mutineer(jobs: 1)
    parallel = run_mutineer(jobs: 4)
    assert_equal serial.mutation_score, parallel.mutation_score
    assert_equal serial.killed_count, parallel.killed_count
    assert_equal survivor_keys(serial), survivor_keys(parallel)
  end

  def test_strategy_redefine_matches_reload
    a = run_mutineer(strategy: "reload", jobs: 1)
    b = run_mutineer(strategy: "redefine", jobs: 1)
    assert_equal a.mutation_score, b.mutation_score
    assert_equal survivor_keys(a), survivor_keys(b)
  end

  def run_namespaced(strategy:)
    config = Mutineer::Config.new(
      sources: ["test/fixtures/namespaced.rb"],
      tests: ["test/fixtures/namespaced_test.rb"],
      cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT,
      strategy: strategy, jobs: 1
    )
    Mutineer::Runner.execute(config).first
  end

  # C2 proof: a MULTI-STATEMENT, NAMESPACED method run end-to-end under BOTH
  # strategies must yield IDENTICAL survivor sets. The surviving mutation
  # (`base * RATE` -> `/`) references an UNQUALIFIED enclosing-namespace constant,
  # which the old 7b turned into a NameError (a different verdict). It also proves
  # statement_removal generates a mutation here (the body has >=2 statements).
  def test_namespaced_multistatement_redefine_equals_reload
    a = run_namespaced(strategy: "reload")
    b = run_namespaced(strategy: "redefine")

    assert_equal survivor_keys(a), survivor_keys(b), "reload and redefine survivor sets must match"
    assert_equal a.killed_count, b.killed_count
    assert_equal a.errored_count, b.errored_count
    assert_equal [["total", "/"]], survivor_keys(a), "the RATE-referencing no-op mutation survives"
    assert_equal 0, a.errored_count, "no spurious NameError under redefine (constant resolves)"

    removals = a.results.count { |r| r.mutation&.operator == :statement_removal }
    assert_operator removals, :>=, 1, "statement_removal must run on the multi-statement body"
  end

  # #279: a method that reads a file through `__dir__` gives the same verdicts
  # under both strategies. Before the fix, redefine loaded the method from the
  # temp dir, so the read raised ENOENT and the equivalent mutant died too.
  def test_path_relative_method_redefine_equals_reload
    a, b = %w[reload redefine].map do |strategy|
      Mutineer::Runner.execute(Mutineer::Config.new(
        sources: ["test/fixtures/path_relative.rb"], tests: ["test/fixtures/path_relative_test.rb"],
        operators: ["arithmetic"], cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: ROOT,
        strategy: strategy, jobs: 1
      )).first
    end
    assert_equal [["shout", "-"]], survivor_keys(a), "the equivalent `+ 0` mutant survives under reload"
    assert_equal survivor_keys(a), survivor_keys(b), "redefine must not falsely kill it"
    assert_equal a.killed_count, b.killed_count
  end

  # A read-only source dir still runs under redefine, and the run warns that
  # path-relative methods there can be falsely killed (#279 review).
  def test_redefine_warns_about_a_read_only_source_dir
    skip "root can write a read-only dir" if Process.uid.zero?
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      Dir.mkdir(lib)
      File.write(File.join(lib, "ro279.rb"), "class Ro279\n  def two\n    1 + 1\n  end\nend\n")
      File.write(File.join(dir, "ro279_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "lib/ro279"
        class Ro279Test < Minitest::Test
          def test_two = assert_equal(2, Ro279.new.two)
        end
      RUBY
      File.chmod(0o555, lib)
      result = nil
      _out, err = capture_io do
        result, = Mutineer::Runner.execute(Mutineer::Config.new(
          sources: [File.join(lib, "ro279.rb")], tests: [File.join(dir, "ro279_test.rb")], operators: ["arithmetic"],
          cache_dir: Dir.mktmpdir("mutineer-cache"), project_root: dir, strategy: "redefine", jobs: 1
        ))
      end
      assert_match(/#{Regexp.escape(File.basename(lib))} is not writable: redefine/, err)
      assert_operator result.killed_count, :>=, 1, "mutants still run from the temp dir"
    ensure
      File.chmod(0o755, lib) if File.directory?(lib)
    end
  end

  # apply_surgical writes its file beside the source and hidden, as
  # apply_whole_file does (#279).
  def test_apply_surgical_loads_beside_the_source
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, "lib"))
      src = "class S279\n  def where\n    __dir__\n  end\nend\n"
      loaded = Dir.chdir(dir) do
        surgical_result(src, namespace: ["S279"], singleton: false,
                             token: "__dir__", replacement: "__FILE__", call: "S279.new.where", file: "lib/x.rb")
      end
      assert_equal File.join(File.realpath(dir), "lib"), File.dirname(loaded)
      assert_match(/\A\.mutineer_mutant/, File.basename(loaded))
    end
  end

  # A read-only source dir falls back to the system temp dir, as in 1.x, so
  # redefine keeps working there (#279 review).
  def test_apply_surgical_falls_back_to_tmpdir_for_read_only_source
    skip "root can write a read-only dir" if Process.uid.zero?
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      Dir.mkdir(lib)
      File.chmod(0o555, lib)
      loaded = Dir.chdir(dir) do
        surgical_result("class S279RO\n  def where\n    __dir__\n  end\nend\n", namespace: ["S279RO"], singleton: false,
                        token: "__dir__", replacement: "__FILE__", call: "S279RO.new.where", file: "lib/x.rb")
      end
      assert_equal File.realpath(Dir.tmpdir), File.realpath(File.dirname(loaded))
    ensure
      File.chmod(0o755, lib) if File.directory?(lib)
    end
  end

  # A second run must not sweep a redefine file while its loader uses it.
  def test_apply_surgical_keeps_its_file_during_another_runs_sweep
    Dir.mktmpdir do |dir|
      source = "def surgical_lock_279; 1; end\n"
      node = Mutineer::Parser.parse_string(source).value.statements.body.first
      subject = Mutineer::Subject.new(file: File.join(dir, "x.rb"), namespace: [],
                                    name: node.name, singleton: false, def_node: node)
      offset = source.index("1")
      mutation = Mutineer::Mutation.new(start_offset: offset, end_offset: offset + 1,
                                      replacement: "9", operator: :literal_mutation)
      loaded = nil
      loader = lambda do |path|
        pid = fork do
          Mutineer::JobPlan.sweep_orphans([dir])
          exit!(0)
        end
        wait_child(pid)
        assert_path_exists path, "another run must leave the active snippet in place"
        loaded = path
      end
      Mutineer::Isolation.stub(:load, loader) do
        Mutineer::Isolation.apply_surgical(mutation, subject, source)
      end
      refute_path_exists loaded, "the snippet must be removed after loading"
    end
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
      def_node = Mutineer::Parser.parse_string(src).value.statements.body.first.body.body.first
      subject = Mutineer::Subject.new(file: File.join(Dir.tmpdir, "x.rb"), namespace: ["S7bMB"],
                                    name: def_node.name, singleton: false, def_node: def_node)
      off = src.byteindex("1")
      mutation = Mutineer::Mutation.new(start_offset: off, end_offset: off + 1,
                                      replacement: "9", operator: :literal_mutation)
      Mutineer::Isolation.apply_surgical(mutation, subject, src)
      wr.write(eval("S7bMB.new.val", TOPLEVEL_BINDING).to_s) # rubocop:disable Security/Eval
      wr.close
      exit!(0)
    end
    wr.close
    reader = Thread.new { rd.read }
    wait_child(pid)
    out = reader.value
    rd.close
    assert_equal "9", out
  end

  private

  # Defines the source in a forked child, applies the surgical mutation, and
  # returns the post-mutation value of `call` as a string. The snippet file is
  # written beside `file`, so the default keeps it out of the checkout.
  def surgical_result(src, namespace:, singleton:, token:, replacement:, call:, file: File.join(Dir.tmpdir, "x.rb"))
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      eval(src, TOPLEVEL_BINDING) # rubocop:disable Security/Eval
      def_node = Mutineer::Parser.parse_string(src).value.statements.body.first.body.body.first
      subject = Mutineer::Subject.new(file: file, namespace: namespace,
                                    name: def_node.name, singleton: singleton, def_node: def_node)
      off = src.index(token)
      mutation = Mutineer::Mutation.new(start_offset: off, end_offset: off + token.length,
                                      replacement: replacement, operator: :literal_mutation)
      Mutineer::Isolation.apply_surgical(mutation, subject, src)
      wr.write(eval(call, TOPLEVEL_BINDING).to_s) # rubocop:disable Security/Eval
      wr.close
      exit!(0)
    end
    wr.close
    reader = Thread.new { rd.read }
    wait_child(pid)
    out = reader.value
    rd.close
    out
  end
end
