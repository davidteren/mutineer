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
    doc = run_report(strategy, sources: sources, test: test)
    assert_empty doc["details"], "#{strategy} errored"
    doc["rows"]
  end

  # @return [Hash] the subjects' sorted statuses ("rows") and the distinct
  #   details of the errored mutants ("details").
  def run_report(strategy, sources:, test:)
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
      JSON.parse(out.lines.last)
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

  # #512: a plain local write in the superclass wraps only the written value,
  # so the local is still set. Any other local write keeps the text as
  # written, because the block would scope the local away from a later line.
  def test_a_superclass_local_write_wraps_only_the_value
    code = "class Q < (base = Struct.new(:a))\nend\nbase.new(1)\n"
    assert_equal "class Q < (base = ::Mutineer::ReloadGuards.kept_superclass(::Module.nesting.first, :Q) " \
                 "{ Struct.new(:a) })\nend\nbase.new(1)\n", Mutineer::JobPlan.keep_live_superclasses(code)
    code = "class Q < base = Struct.new(:a)\nend\n"
    assert_includes Mutineer::JobPlan.keep_live_superclasses(code), "< base = ::Mutineer::ReloadGuards.kept_superclass("
    code = "class Q < (a = b = Struct.new(:a))\nend\n"
    assert_includes Mutineer::JobPlan.keep_live_superclasses(code), "(a = b = ::Mutineer::ReloadGuards.kept_superclass("
  end

  # #512: these keep the superclass as written, so the file still errors,
  # visibly, when its call builds a new class (#527).
  def test_a_superclass_that_sets_a_local_another_way_is_not_wrapped
    ["(base = Parent)", "(base ||= Struct.new(:a))", "(base, = Struct.new(:a))", "((base = Struct.new(:a)))",
     "(tmp = 1; Struct.new(:a))"].each do |superclass|
      code = "class Q < #{superclass}\nend\nbase.new(1)\n"
      assert_same code, Mutineer::JobPlan.keep_live_superclasses(code), superclass
    end
    code = "class R < Struct.new(:a) { x = 1 }\nend\n"
    assert_includes Mutineer::JobPlan.keep_live_superclasses(code), "kept_superclass"
    # The same block write reaches the file's local when the file set it first.
    code = "x = 0\nclass R < Struct.new(:a) { x = 1 }\nend\nx\n"
    assert_same code, Mutineer::JobPlan.keep_live_superclasses(code)
    code = "x = 0\nclass R < Struct.new(:a) { -> { x += 1 } }\nend\n"
    assert_same code, Mutineer::JobPlan.keep_live_superclasses(code)
    code = "x = 0\nclass R < (b = Struct.new(:a) { x = 1 })\nend\n"
    assert_same code, Mutineer::JobPlan.keep_live_superclasses(code)
  end

  # R16 of the #512 plan: an earlier line sets the variable and runs again on
  # reload, so a kept parent would differ from what the variable then holds.
  # A method call is still wrapped: nothing else holds its result.
  def test_a_superclass_that_reads_a_variable_is_not_wrapped
    %w[base @base @@base $base].each do |read|
      code = "#{read} = Struct.new(:v)\nclass LocalRow < #{read}\nend\n"
      assert_same code, Mutineer::JobPlan.keep_live_superclasses(code), read
    end
    code = "class Q < base_class\nend\n"
    assert_includes Mutineer::JobPlan.keep_live_superclasses(code), "kept_superclass(::Module.nesting.first, :Q) { base_class }"
  end

  # Test the rule, not the example: each superclass text loads, then its
  # rewrite loads over it. A changed text reopens the class with no error, keeps
  # its line count, and leaves each local it sets on the live superclass. An
  # unchanged text is the same String.
  SUPERCLASS_SHAPES = {
    "(base = Struct.new(:a))" => %w[base],
    "base = Struct.new(:a)" => %w[base],
    "(a = b = Struct.new(:a))" => %w[a b],
    "(base = Data.define(:a))" => %w[base],
    "(base = Class.new(StandardError))" => %w[base],
    "(base = Struct.new(:a) { def x = 1 })" => %w[base],
    "(base = Struct.new(:a) { y = 1 })" => %w[base],
    "base = (Struct.new(:a))" => %w[base],
    "(base =\n  Struct.new(\n    :a\n  ))" => %w[base],
    "Struct.new(:a)" => [],
    "(Struct.new(:a))" => [],
    "(base = String)" => nil,
    "(base ||= Struct.new(:a))" => nil,
    "(base, = Struct.new(:a))" => nil,
    "((base = Struct.new(:a)))" => nil,
    "(tmp = 1; Struct.new(:a))" => nil
  }.freeze

  def test_every_local_write_shape_loads_twice_or_stays_as_written
    SUPERCLASS_SHAPES.each_with_index do |(superclass, locals), index|
      name = "LocalShape#{index}"
      code = "class #{name} < #{superclass}\nend\n"
      rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
      if locals.nil?
        assert_same code, rewritten, superclass
        next
      end
      refute_equal code, rewritten, superclass
      assert_equal code.lines.size, rewritten.lines.size, superclass
      checks = locals.map { |local| "raise #{local.inspect} unless #{local}.equal?(#{name}.superclass)\n" }.join
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "original.rb"), code + checks)
        File.write(File.join(dir, "rewritten.rb"), rewritten + checks)
        script = "require 'mutineer/reload_guards'; first = nil\n" \
                 "load #{File.join(dir, "original.rb").inspect}; first = #{name}\n" \
                 "load #{File.join(dir, "rewritten.rb").inspect}\n" \
                 "raise 'a new class' unless first.equal?(#{name})"
        _out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script)
        assert status.success?, "#{superclass}: #{err}"
      end
    end
  end

  # #512: AE1. The file sets a local in the superclass expression and reads
  # it on a later line. Reload scores it like redefine.
  def test_reload_scores_a_superclass_that_sets_a_local_like_redefine
    reload = run_strategy("reload", sources: %w[local_superclass.rb], test: "local_superclass_test.rb")
    redefine = run_strategy("redefine", sources: %w[local_superclass.rb], test: "local_superclass_test.rb")
    assert_equal ["killed"], reload["Quad#four?"].uniq
    assert_equal ["killed"], reload["Plain#five?"].uniq
    assert_equal redefine, reload
  end

  # R16 of the #512 plan: AE9. A superclass that reads a variable is not
  # wrapped, so the file errors visibly, as in 1.9.0, instead of giving the
  # false verdicts of a kept parent.
  def test_reload_errors_on_a_superclass_that_reads_a_variable
    doc = run_report("reload", sources: %w[local_read_superclass.rb], test: "local_read_superclass_test.rb")
    assert_equal ["error"], doc["rows"].values.flatten.uniq
    assert(doc["details"].all? { |detail| detail.include?("superclass mismatch") }, doc["details"].inspect)
  end

  def test_the_rewrite_names_the_scope_each_class_statement_defines_in
    code = "class X < Data.define(:a)\nend\nclass A::B::Y < Struct.new(:b)\nend\nclass ::Z < Class.new\nend\n"
    rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
    assert_includes rewritten, "kept_superclass(::Module.nesting.first, :X) { Data.define(:a) }"
    assert_includes rewritten, "kept_superclass(A::B, :Y) { Struct.new(:b) }"
    assert_includes rewritten, "kept_superclass(::Object, :Z) { Class.new }"
  end

  # The scope lookup is rooted, so a namespace constant named `Module` cannot
  # shadow it. The second load reopens the class instead of raising.
  def test_a_namespace_constant_named_module_does_not_shadow_the_scope_lookup
    code = "module CallSuperShadow\n  class Module < Struct.new(:title)\n    def label = title\n  end\nend\n"
    rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "shadow.rb")
      File.write(file, rewritten)
      load file
      first = CallSuperShadow::Module
      load file
      assert_same first, CallSuperShadow::Module
      assert_equal "t", CallSuperShadow::Module.new("t").label
    end
  ensure
    Object.send(:remove_const, :CallSuperShadow) if Object.const_defined?(:CallSuperShadow, false)
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
    assert_includes code, "kept_superclass(::Module.nesting.first, :InclusionValue)"
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
