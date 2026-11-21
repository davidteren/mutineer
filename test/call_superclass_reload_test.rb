# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# #492: reload loads the mutant file over a class that exists. A class whose
# superclass is a call (`Data.define`, `Struct.new`, ...) builds a new
# superclass each time, so Ruby raised "superclass mismatch" and every mutant
# of the file scored `error`. Reload now reopens the class with the superclass
# it has, so its verdicts match redefine, which never runs the class body again.
class CallSuperclassReloadTest < Minitest::Test
  ROOT = File.expand_path("fixtures", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  # Runs one fresh process, so each strategy starts from the original classes.
  #
  # @return [Hash{String => Array<String>}] each subject's sorted statuses.
  def run_strategy(strategy, sources:, test:)
    Dir.mktmpdir("mutineer-call-superclass") do |cache|
      script = <<~RUBY
        require "mutineer"
        require "json"
        config = Mutineer::Config.new(sources: #{sources.inspect}, tests: [#{test.inspect}],
                                      strategy: #{strategy.inspect}, project_root: #{ROOT.inspect},
                                      cache_dir: #{cache.inspect}, jobs: 1)
        agg = Mutineer::Runner.execute(config).first
        rows = Hash.new { |h, k| h[k] = [] }
        agg.results.each { |r| rows[r.subject.qualified_name] << r.status.to_s }
        details = agg.results.select(&:error?).map(&:details).uniq
        $stdout.puts JSON.generate("rows" => rows.transform_values(&:sort), "details" => details)
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script, chdir: ROOT)
      assert status.success?, "#{strategy} run failed: #{err}"
      doc = JSON.parse(out.lines.last)
      assert_empty doc["details"], "#{strategy} errored"
      doc["rows"]
    end
  end

  def values_run(test)
    %w[reload redefine].to_h do |strategy|
      [strategy, run_strategy(strategy, sources: %w[call_superclass.rb call_superclass_holders.rb], test: test)]
    end
  end

  def test_reload_scores_a_data_define_class_like_redefine
    rows = values_run("call_superclass_test.rb")
    assert_includes rows["reload"]["InclusionValue#switch?"], "killed"
    refute rows["reload"].values.flatten.include?("error")
    assert_equal rows["redefine"], rows["reload"]
  end

  # A new class object would make Data#== false here and kill every mutant.
  def test_an_instance_another_file_kept_still_equals_a_new_one
    rows = values_run("call_superclass_holder_eq_test.rb")
    assert_equal rows["redefine"], rows["reload"]
  end

  # A new class object would leave the subclass on the old parent, so the
  # mutant would not reach the test and would survive.
  def test_a_subclass_in_another_file_reaches_the_mutant
    rows = values_run("call_superclass_subclass_test.rb")
    assert_includes rows["reload"]["InclusionValue#switch?"], "killed"
    assert_equal rows["redefine"], rows["reload"]
  end

  def test_the_rewrite_leaves_constant_superclasses_alone
    code = "class A < B\nend\nclass C < D::E\nend\nclass F\nend\n"
    assert_same code, Mutineer::JobPlan.keep_live_superclasses(code)
  end

  # Each shape parses after the rewrite and keeps its line count, so a
  # backtrace line and the coverage map still match the source.
  def test_the_rewrite_parses_and_keeps_lines_for_every_shape
    %w[call_superclass.rb call_superclass_shapes.rb].each do |name|
      code = File.read(File.join(ROOT, name))
      rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
      refute_equal code, rewritten, name
      refute Mutineer::Parser.invalid?(rewritten), name
      assert_equal code.lines.size, rewritten.lines.size, name
    end
  end

  # A class inside a wrapped superclass is skipped with it, so the two wraps
  # never overlap and the text still parses.
  def test_a_class_inside_a_superclass_block_is_not_wrapped_twice
    code = "class Outer < Class.new(Struct.new(:a)) {\n  class Inner < Struct.new(:b); end\n}\nend\n"
    rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
    assert_equal 1, rewritten.scan("kept_superclass").size
    refute Mutineer::Parser.invalid?(rewritten)
  end

  def test_the_rewrite_names_the_scope_each_class_statement_defines_in
    code = "class X < Data.define(:a)\nend\nclass A::B::Y < Struct.new(:b)\nend\nclass ::Z < Class.new\nend\n"
    rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
    assert_includes rewritten, "kept_superclass(Module.nesting.first, :X) { Data.define(:a) }"
    assert_includes rewritten, "kept_superclass(A::B, :Y) { Struct.new(:b) }"
    assert_includes rewritten, "kept_superclass(::Object, :Z) { Class.new }"
  end

  # The reach probe and the hook-def insert come first, then the rewrite.
  def test_reload_code_rewrites_after_the_reach_probe
    source = File.read(File.join(ROOT, "call_superclass.rb"))
    subject = Mutineer::Project.discover([File.join(ROOT, "call_superclass.rb")], only: "InclusionValue#switch?").first
    body = subject.body_loc
    mutation = Mutineer::Mutation.new(start_offset: body.start_offset, end_offset: body.end_offset,
                                      replacement: "true", operator: "test")
    code, hook_def = Mutineer::JobPlan.reload_code(mutation.apply(source), mutation, subject, source,
                                                   reach_path: "/tmp/x", reach_key: "mutineer_r0123456789abcdef")
    assert_nil hook_def
    assert_includes code, "kept_superclass(Module.nesting.first, :InclusionValue)"
    assert_includes code, "mutineer_r0123456789abcdef"
    refute Mutineer::Parser.invalid?(code)
  end

  def test_kept_superclass_returns_the_live_superclass_or_runs_the_block
    parent = Class.new
    scope = Module.new
    scope.const_set(:Kept, Class.new(parent))
    scope.const_set(:NotAClass, Module.new)
    fresh = Class.new
    assert_same parent, Mutineer::ReloadGuards.kept_superclass(scope, :Kept) { fresh }
    assert_same fresh, Mutineer::ReloadGuards.kept_superclass(scope, :Missing) { fresh }
    assert_same fresh, Mutineer::ReloadGuards.kept_superclass(scope, :NotAClass) { fresh }
    assert_same String.superclass, Mutineer::ReloadGuards.kept_superclass(nil, :String) { fresh }
    # Only the named scope counts, not a top-level class of the same name.
    assert_same fresh, Mutineer::ReloadGuards.kept_superclass(scope, :String) { fresh }
  end

  # The daemon child loads the payload text the backend built, so it reopens
  # the class. Runs in a fork, as the daemon does.
  def test_the_daemon_child_reloads_a_call_superclass
    require "mutineer/daemon_server"
    file = File.join(ROOT, "call_superclass.rb")
    source = File.read(file)
    subject = Mutineer::Project.discover([file], only: "InclusionValue#switch?").first
    body = subject.body_loc
    mutation = Mutineer::Mutation.new(start_offset: body.start_offset, end_offset: body.end_offset,
                                      replacement: "true", operator: "test")
    code, = Mutineer::JobPlan.reload_code(mutation.apply(source), mutation, subject, source)
    sent = JSON.parse(JSON.generate("code" => code, "source_file" => file))
    result = Mutineer::Isolation.run do
      $stderr.reopen(File::NULL)
      load file
      before = InclusionValue
      Mutineer::DaemonServer.send(:apply_payload, sent)
      InclusionValue.equal?(before) && InclusionValue.new(type: "x", value: 1).switch? ? 0 : 1
    end
    assert_predicate result, :survived?, "the same class must reopen with the mutated method"
  end

  # Cover the siblings: every non-constant superclass shape gets a verdict. A
  # method inside the superclass call's block is unplaceable under both
  # strategies, because neither runs that block again.
  def test_every_superclass_call_shape_reloads
    reload = run_strategy("reload", sources: %w[call_superclass_shapes.rb], test: "call_superclass_shapes_test.rb")
    redefine = run_strategy("redefine", sources: %w[call_superclass_shapes.rb], test: "call_superclass_shapes_test.rb")
    assert_equal ["unplaceable"], reload["BlockStruct#in_block?"].uniq
    assert_includes reload["BlockStruct#in_body?"], "killed"
    refute reload.values.flatten.include?("error")
    assert_equal redefine, reload
  end
end
