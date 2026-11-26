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

  # Review of #541: a wrap is a new block, so a numbered parameter or `it` of
  # an outer block inside the wrapped text would change meaning or not parse.
  # Such a superclass is left as written.
  def test_a_superclass_that_reads_an_outer_block_parameter_is_not_wrapped
    ["[Struct].each { class Q < (b = _1.new(:a)); end }\n",
     "[Struct].each { class Q < it.new(:a); end }\n",
     "[1].each { _1\n  class Q < Struct.new(_1); end }\n"].each do |code|
      assert_same code, Mutineer::JobPlan.keep_live_superclasses(code), code
    end
    # A block of the superclass call that uses its own `_1` is still wrapped.
    code = "class Q < Struct.new(:a) { [1].map { _1 } }\nend\n"
    assert_includes Mutineer::JobPlan.keep_live_superclasses(code), "kept_superclass"
  end

  # R16 of the #512 plan: an earlier line sets the variable and runs again on
  # reload, so a kept parent would differ from what the variable then holds.
  # A method call is still wrapped: nothing else holds its result.
  def test_a_superclass_that_reads_a_variable_is_not_wrapped
    %w[base @base @@base $base (base) ((@base))].each do |read|
      code = "#{read.delete("()")} = Struct.new(:v)\nclass LocalRow < #{read}\nend\n"
      assert_same code, Mutineer::JobPlan.keep_live_superclasses(code), read
    end
    code = "class LocalRow < (Parent)\nend\n"
    assert_same code, Mutineer::JobPlan.keep_live_superclasses(code)
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

  def const_run(test)
    %w[reload redefine].to_h do |strategy|
      [strategy, run_strategy(strategy, sources: %w[const_superclass.rb const_superclass_holders.rb], test: test)]
    end
  end

  # #503: AE3, AE5. The file assigns the constant its class inherits from.
  # Reload keeps that constant's class and scores the class body like
  # redefine. #528, AE8: the kept value's block runs again on the live class,
  # so its method gets a real verdict too.
  def test_reload_scores_a_class_whose_superclass_constant_the_file_assigns
    rows = const_run("const_superclass_test.rb")
    assert_equal ["killed"], rows["reload"]["Row#three?"].uniq
    assert_equal ["survived"], rows["reload"]["Row#weak?"].uniq
    assert_equal ["killed"], rows["reload"]["Ledger::Credit#zero?"].uniq
    assert_equal ["killed"], rows["reload"]["BaseRow#in_block?"].uniq
    assert_equal rows["redefine"], rows["reload"]
  end

  # #503: AE4. A subclass and an instance in another file keep the same
  # class, so the mutant reaches the subclass, and the held instance is still
  # a BaseRow equal to a new Row.
  def test_a_kept_superclass_constant_keeps_subclasses_and_instances
    rows = const_run("const_superclass_subclass_test.rb")
    assert_equal ["killed"], rows["reload"]["Row#three?"].uniq
    assert_equal ["survived"], rows["reload"]["Ledger::Credit#zero?"].uniq
    assert_equal rows["redefine"], rows["reload"]
  end

  def test_the_rewrite_keeps_a_superclass_constant_the_file_assigns
    code = "BaseRow = Struct.new(:v)\nclass Row < BaseRow\nend\n"
    assert_equal "BaseRow = ::Mutineer::ReloadGuards.kept_constant(::Module.nesting.first, :BaseRow) " \
                 "{ Struct.new(:v) }\nclass Row < BaseRow\nend\n", Mutineer::JobPlan.keep_live_superclasses(code)
    code = "Billing::Base = Class.new\nclass Billing::Row < Billing::Base\nend\n"
    assert_includes Mutineer::JobPlan.keep_live_superclasses(code),
                    "Billing::Base = ::Mutineer::ReloadGuards.kept_constant(Billing, :Base) { Class.new }"
    code = "::Base = Class.new\nclass Row < ::Base\nend\nmodule M\n  self::Kid = Class.new\n  class Row < self::Kid\n  end\nend\n"
    rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
    assert_includes rewritten, "::Base = ::Mutineer::ReloadGuards.kept_constant(::Object, :Base) { Class.new }"
    assert_includes rewritten, "self::Kid = ::Mutineer::ReloadGuards.kept_constant(self, :Kid) { Class.new }"
    code = "Base = Class.new\nclass Row < ::Base\nend\n"
    assert_includes Mutineer::JobPlan.keep_live_superclasses(code), "Base = ::Mutineer::ReloadGuards.kept_constant("
    # A local write in the value is not a builder call, so it is left as written.
    code = "Base = (b = Struct.new(:v))\nclass Row < Base\nend\nb\n"
    assert_same code, Mutineer::JobPlan.keep_live_superclasses(code)
    # #528: a builder block that can run again keeps its place, after the call.
    code = "Base = Struct.new(:v, \"w\", 1, keyword_init: true) do\n  def x = 1\nend\nclass Row < Base\nend\n"
    assert_includes Mutineer::JobPlan.keep_live_superclasses(code),
                    "Base = ::Mutineer::ReloadGuards.reopened_constant(::Module.nesting.first, :Base, " \
                    "-> { Struct.new(:v, \"w\", 1, keyword_init: true) }) do\n  def x = 1\nend\n"
  end

  # #528: no class statement has to name a literal builder constant. Each text
  # gives the expected rewrite, parses, and keeps its line count.
  def test_the_rewrite_keeps_every_literal_builder_constant
    {
      "Point = Struct.new(:x) { def a = 1 }\n" =>
        "Point = ::Mutineer::ReloadGuards.reopened_constant(::Module.nesting.first, :Point, -> { Struct.new(:x) }) " \
        "{ def a = 1 }\n",
      "Billing::Base = Class.new do\n  def a = 1\nend\n" =>
        "Billing::Base = ::Mutineer::ReloadGuards.reopened_constant(Billing, :Base, -> { Class.new }) do\n",
      "Point = Struct.new(\n  :x,\n  :y\n) do\n  def a = 1\nend\n" =>
        "Point = ::Mutineer::ReloadGuards.reopened_constant(::Module.nesting.first, :Point, -> { Struct.new(\n  :x,\n  :y\n) }) do\n",
      "X = Struct.new(:x) \\\n  do\n  def a = 1\nend\n" =>
        "X = ::Mutineer::ReloadGuards.reopened_constant(::Module.nesting.first, :X, -> { Struct.new(:x) \\\n  }) do\n",
      "Other = Struct.new(:v)\nclass Row < BaseRow\nend\n" =>
        "Other = ::Mutineer::ReloadGuards.kept_constant(::Module.nesting.first, :Other) { Struct.new(:v) }\n",
      "Base = Struct.new(:v)\nclass User < ActiveRecord::Base\nend\n" =>
        "Base = ::Mutineer::ReloadGuards.kept_constant(::Module.nesting.first, :Base) { Struct.new(:v) }\n",
      "Other::Base = Struct.new(:v)\nclass User < ActiveRecord::Base\nend\n" =>
        "Other::Base = ::Mutineer::ReloadGuards.kept_constant(Other, :Base) { Struct.new(:v) }\n",
      "Other::Base = Struct.new(:v)\nclass User < Base\nend\n" =>
        "Other::Base = ::Mutineer::ReloadGuards.kept_constant(Other, :Base) { Struct.new(:v) }\n",
      # The builder with an argument that is not a literal keeps its text (#575).
      "Fields = Struct.new(:v)\nBaseRow = Class.new(Fields)\nclass Row < BaseRow\nend\n" =>
        "Fields = ::Mutineer::ReloadGuards.kept_constant(::Module.nesting.first, :Fields) { Struct.new(:v) }\n" \
        "BaseRow = Class.new(Fields)\n"
    }.each do |code, expected|
      rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
      assert_includes rewritten, expected, code
      refute Mutineer::Parser.invalid?(rewritten), rewritten
      assert_equal code.lines.size, rewritten.lines.size, rewritten
    end
  end

  # #503: AE8. These come back as the same String: the value is a constant or
  # a variable read, the write is `||=` (#529) or a multiple assignment (#527),
  # or the file writes the name twice (#528, AE17).
  def test_the_rewrite_leaves_other_constant_writes_alone
    ["BaseRow = Parent\nclass Row < BaseRow\nend\n",
     "BaseRow = Parent::Kid\nclass Row < BaseRow\nend\n",
     "BaseRow ||= Struct.new(:v)\nclass Row < BaseRow\nend\n",
     "base = Struct.new(:v)\nBaseRow = base\nclass Row < BaseRow\nend\n",
     "A, BaseRow = 1, Struct.new(:v)\nclass Row < BaseRow\nend\n",
     # #528, AE17: a name the file writes twice is not kept, by any kind of write.
     "Cell = Struct.new(:x)\nFirst = Cell\nCell = Struct.new(:y)\n",
     "Cell = Struct.new(:x)\nCell ||= 1\n",
     "Cell = Struct.new(:x)\nA::Cell = 1\n",
     "Cell = Struct.new(:x)\nA, Cell = 1, 2\n",
     # AE14, R16: no call superclass and no literal builder constant.
     "class A < B\nend\nX = 1\nY = build\n",
     # Fail closed: only a Struct.new, Data.define or Class.new with literal
     # arguments is kept. A builder method of the file, or an argument that can
     # name a class the file builds again, would keep a stale class.
     "BaseRow = build_base\nclass Row < BaseRow\nend\n",
     "BaseRow = Struct.new(*FIELDS)\nclass Row < BaseRow\nend\n",
     "BaseRow = Struct.new(:v, &BLOCK)\nclass Row < BaseRow\nend\n",
     "BaseRow = Factory.new(:v)\nclass Row < BaseRow\nend\n",
     # A path whose parent is not a constant would run that parent twice.
     "registry.next::Base = Struct.new(:v)\nclass Row < registry.next::Base\nend\n"].each do |code|
      assert_same code, Mutineer::JobPlan.keep_live_superclasses(code), code
    end
  end

  # The walk does not enter a kept value that does not run again, so a class
  # inside it is not wrapped again: two splices in one range would not parse.
  # A reopened block runs again, so the walk wraps a class inside it (#528).
  def test_a_class_inside_a_kept_constant_is_not_wrapped
    code = "Base = Class.new do\n  alias_method :b, :a\n  class Inner < Struct.new(:b); end\nend\nclass Row < Base\nend\n"
    rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
    assert_equal 1, rewritten.scan("::Mutineer::ReloadGuards.").size
    assert_includes rewritten, "kept_constant"
    refute Mutineer::Parser.invalid?(rewritten)
    code = "Base = Class.new do\n  class Inner < Struct.new(:b); end\nend\nclass Row < Base\nend\n"
    rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
    assert_equal 1, rewritten.scan("reopened_constant").size
    assert_equal 1, rewritten.scan("kept_superclass").size
    refute Mutineer::Parser.invalid?(rewritten)
  end

  def test_the_constant_fixture_rewrite_parses_keeps_lines_and_loads_twice
    code = File.read(File.join(ROOT, "const_superclass.rb"))
    rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
    refute Mutineer::Parser.invalid?(rewritten)
    assert_equal code.lines.size, rewritten.lines.size
    Dir.mktmpdir do |dir|
      original = File.join(dir, "original.rb")
      mutant = File.join(dir, "rewritten.rb")
      File.write(original, code)
      File.write(mutant, rewritten)
      script = "require 'mutineer/reload_guards'\nload #{original.inspect}\nbase = BaseRow; entry = Ledger::Entry\n" \
               "load #{mutant.inspect}\n" \
               "raise 'BaseRow' unless BaseRow.equal?(base) && Row.superclass.equal?(BaseRow)\n" \
               "raise 'Entry' unless Ledger::Entry.equal?(entry) && Ledger::Credit.superclass.equal?(entry)\n" \
               "raise 'block' unless BaseRow.instance_method(:in_block?).source_location.first == #{mutant.inspect}"
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script)
      assert status.success?, err
    end
  end

  def test_kept_constant_returns_the_live_class_or_runs_the_block
    scope = Module.new
    live = Class.new
    scope.const_set(:Kept, live)
    scope.const_set(:NotAClass, 1)
    fresh = Class.new
    assert_same live, Mutineer::ReloadGuards.kept_constant(scope, :Kept) { fresh }
    assert_same fresh, Mutineer::ReloadGuards.kept_constant(scope, :Missing) { fresh }
    assert_same fresh, Mutineer::ReloadGuards.kept_constant(scope, :NotAClass) { fresh }
    assert_same String, Mutineer::ReloadGuards.kept_constant(nil, :String) { fresh }
    # Only the named scope counts, not a top-level class of the same name.
    assert_same fresh, Mutineer::ReloadGuards.kept_constant(scope, :String) { fresh }
  end

  # #503, test the rule (R7 of the plan): discovery marks every def that the
  # reload text keeps in a block, so none of them gets a silent verdict.
  # Checked on every fixture file and every shape text of this file.
  def test_every_def_in_a_kept_value_is_unplaceable_under_reload
    texts = Dir.glob(File.join(ROOT, "**", "*.rb")).reject { |path| path.end_with?("_test.rb") }.map { |path| File.read(path) }
    texts += ["class K < Struct.new(:a) do\n  def k1; end\nend\nend\n",
              "class K < (base = Struct.new(:a) { def k2; end })\nend\n",
              "class K < base = Struct.new(:a) { def k3; end }\nend\n",
              "class K < (a = b = Data.define(:a) { def k4; end })\nend\n",
              "BaseRow = Struct.new(:v) do\n  alias_method :b, :v\n  def k5; end\nend\nclass Row < BaseRow\nend\n",
              "Base = Data.define(:v) do\n  alias_method :b, :v\n  def k6; end\nend\nclass Row < Base\nend\n",
              "module M\n  M::Base = Class.new do\n    alias_method :b, :a\n    def k7; end\n  end\nend\nclass Row < M::Base\nend\n"]
    checked = []
    Dir.mktmpdir do |dir|
      texts.each_with_index do |code, index|
        next if Mutineer::Parser.invalid?(code)

        rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
        next if rewritten.equal?(code)

        kept = kept_def_lines(rewritten)
        next if kept.empty?

        path = File.join(dir, "text#{index}.rb")
        File.write(path, code)
        subjects = Mutineer::Project.discover([path])
        kept.each do |line, name|
          subject = subjects.find { |s| s.def_node.location.start_line == line && s.name == name }
          next unless subject # a def discovery does not select

          checked << name
          assert subject.unplaceable?("reload"), "#{name} on line #{line} of text #{index}"
        end
      end
    end
    # Each shape text above must reach the check, so none drops out unseen.
    assert_empty %i[k1 k2 k3 k4 k5 k6 k7] - checked
  end

  # The line and name of each def inside a kept block of the rewritten text.
  #
  # @return [Array<Array(Integer, Symbol)>]
  def kept_def_lines(rewritten)
    found = []
    queue = [Mutineer::Parser.parse_string(rewritten).value]
    while (node = queue.shift)
      if node.is_a?(Prism::CallNode) && %i[kept_superclass kept_constant].include?(node.name) && node.block
        defs = [node.block]
        while (inner = defs.shift)
          found << [inner.location.start_line, inner.name] if inner.is_a?(Prism::DefNode)
          defs.concat(inner.compact_child_nodes)
        end
      else
        queue.concat(node.compact_child_nodes)
      end
    end
    found
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

  # #529: AE1, AE2. A second load skips the value of a constant `||=` and the
  # statements of a `defined?` guard that define the tested name, so reload
  # cannot place a mutant there: each one is `unplaceable` and counted. A guard
  # that does not define the tested name runs again, so its method is killed.
  def test_reload_marks_a_definition_a_second_load_skips_unplaceable
    skipped = %w[OrCell#one? GuardedCell#two? BlockedCell#three? StatedCell#four? NegatedCell#five?]
    reload = run_strategy("reload", sources: %w[or_constant.rb], test: "or_constant_test.rb")
    skipped.each { |name| assert_equal ["unplaceable"], reload.fetch(name).uniq, name }
    assert_equal ["killed"], reload.fetch("ShimmedCell#six?").uniq
    redefine = run_strategy("redefine", sources: %w[or_constant.rb], test: "or_constant_test.rb")
    assert_equal ["killed"], redefine.values.flatten.uniq
    assert_equal reload.keys.sort, redefine.keys.sort
  end

  # #529: the JSON report counts each such mutant in `summary.unplaceable` and
  # lists it in `unplaceable[]`, so it has its place in the unrun share.
  def test_the_report_counts_a_definition_a_second_load_skips
    Dir.mktmpdir("mutineer-or-constant") do |cache|
      script = <<~RUBY
        require "mutineer"
        require "stringio"
        config = Mutineer::Config.new(sources: ["or_constant.rb"], tests: ["or_constant_test.rb"],
                                      strategy: "reload", project_root: #{ROOT.inspect},
                                      cache_dir: #{cache.inspect}, jobs: 1)
        agg, source_map = Mutineer::Runner.execute(config)
        out = StringIO.new
        Mutineer::Reporter.new(agg, source_map).report(out: out, err: StringIO.new, format: "json")
        $stdout.puts out.string.lines.join.tr("\n", " ")
        $stdout.puts agg.results.count(&:unplaceable?)
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script, chdir: ROOT)
      assert status.success?, err
      doc = JSON.parse(out.lines[-2])
      count = Integer(out.lines.last)
      assert_operator count, :>=, 5
      assert_equal count, doc["summary"]["unplaceable"]
      assert_equal count, doc["unplaceable"].size
      assert_equal %w[BlockedCell#three? GuardedCell#two? NegatedCell#five? OrCell#one? StatedCell#four?],
                   doc["unplaceable"].map { |entry| entry["subject"] }.uniq.sort
    end
  end


  # #528: each builder block text and whether reload may run it again on the
  # live class (`Project.rerunnable_block?`). The second value of a true row
  # is the method the load-twice test checks.
  RERUNNABLE_BLOCKS = {
    "" => [true, nil],
    "def a; end" => [true, "K.instance_method(:a)"],
    "private\n  def a; end" => [true, "K.instance_method(:a)"],
    "private def a = 1" => [true, "K.instance_method(:a)"],
    "attr_reader :b" => [true, nil],
    "attr_writer :b" => [true, nil],
    "attr_accessor :b" => [true, nil],
    "public" => [true, nil],
    "protected" => [true, nil],
    "private_class_method :new" => [true, nil],
    "public_class_method :new" => [true, nil],
    "ZERO = 1" => [true, nil],
    "KEYS = OPTIONS.filter_map(&:key).freeze" => [true, nil],
    "Inner = Struct.new(:b) do\n    alias_method :c, :b\n  end" => [true, nil],
    "class Z\n    def z; end\n  end" => [true, "Z.instance_method(:z)"],
    "module self::Calc\n    def self.p = 1\n  end" => [true, "K::Calc.method(:p)"],
    "class << self\n    def s; end\n  end" => [true, "K.method(:s)"],
    "include Comparable" => [false],
    "extend Forwardable" => [false],
    "alias_method :b, :a" => [false],
    "alias b a" => [false],
    "undef a" => [false],
    "remove_method :a" => [false],
    "define_method(:a) { }" => [false],
    "delegate :a, to: :b" => [false],
    "[1].each { }" => [false],
    "attr_reader(*names)" => [false],
    "helper" => [false],
    "self.x = 1" => [false],
    "ORIG = instance_method(:a)" => [false],
    "ZERO = new(0)" => [false],
    "ME = self" => [false],
    "class Z\n    alias_method :b, :a\n  end" => [false],
    "class << self\n    alias_method :b, :a\n  end" => [false],
    "def a; end\nrescue StandardError\n  nil" => [false]
  }.freeze

  # A block parameter is the class, and reading it can read its earlier state.
  PARAMETER_BLOCKS = ["do |k|\n  ORIG = k.instance_method(:a)\n  def a = 1\nend\n",
                      "do\n  ORIG = _1.instance_method(:a)\n  def a = 1\nend\n",
                      "do\n  ORIG = it.instance_method(:a)\n  def a = 1\nend\n"].freeze

  # #528, R10, test the rule: the answer of `Project.rerunnable_block?` for
  # each statement kind, so a block that reads the class's earlier state
  # never runs again.
  def test_rerunnable_block_accepts_only_statements_that_are_safe_to_run_again
    RERUNNABLE_BLOCKS.each do |body, (expected, _check)|
      block = builder_block("K = Struct.new(:a) do\n  #{body}\nend\n")
      assert_equal expected, Mutineer::Project.rerunnable_block?(block), body
    end
    PARAMETER_BLOCKS.each do |text|
      refute Mutineer::Project.rerunnable_block?(builder_block("K = Struct.new(:a) #{text}")), text
    end
  end

  # #528, R10, the load-twice rule: for each block the rule accepts, a second
  # load of the rewritten text keeps the same class, and each def of the block
  # comes from the second file. So the block really runs again on the live class.
  def test_every_rerunnable_block_loads_twice_onto_the_same_class
    texts = RERUNNABLE_BLOCKS.select { |_body, (expected, _check)| expected }.map do |body, (_expected, check)|
      ["K = Struct.new(:a) do\n  #{body}\nend\n", check ? ["K", check] : ["K"]]
    end
    texts << [File.read(File.join(ROOT, "builder_constant.rb")), ["BuilderPoint", "BuilderPoint.instance_method(:one?)"]]
    texts.each do |code, (constant, check)|
      rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
      assert_includes rewritten, "reopened_constant", code
      Dir.mktmpdir do |dir|
        original = File.join(dir, "original.rb")
        mutant = File.join(dir, "rewritten.rb")
        File.write(original, code)
        File.write(mutant, rewritten)
        script = "require 'mutineer/reload_guards'\nOPTIONS = []\nload #{original.inspect}\nfirst = #{constant}\n" \
                 "load #{mutant.inspect}\nraise 'a new class' unless first.equal?(#{constant})\n"
        script += "raise 'not run again' unless #{check}.source_location.first == #{mutant.inspect}\n" if check
        _out, err, status = Open3.capture3(RbConfig.ruby, "-W0", "-I#{LIB}", "-e", script)
        assert status.success?, "#{code}: #{err}"
      end
    end
  end

  # The block of the one builder call in `code`.
  def builder_block(code)
    program = Mutineer::Parser.parse_string(code).value
    program.statements.body.first.value.block
  end

  # #528: reopened_constant runs the block on the live class, or on the class
  # the builder makes when the scope has none.
  def test_reopened_constant_runs_the_block_on_the_live_class_or_on_a_new_one
    scope = Module.new
    live = Struct.new(:x)
    scope.const_set(:Kept, live)
    result = Mutineer::ReloadGuards.reopened_constant(scope, :Kept, -> { Struct.new(:y) }) { def tag = :reopened }
    assert_same live, result
    assert_equal :reopened, live.new(1).tag
    fresh = Mutineer::ReloadGuards.reopened_constant(scope, :Missing, -> { Struct.new(:y) }) { def tag = :fresh }
    refute_same live, fresh
    assert_equal %i[y], fresh.members
    assert_equal :fresh, fresh.new(1).tag
  end

  def builder_run(test)
    %w[reload redefine].to_h do |strategy|
      [strategy, run_strategy(strategy, sources: %w[builder_constant.rb builder_constant_holders.rb], test: test)]
    end
  end

  # #528: AE6. A subclass and an instance in another file reach the mutant,
  # because reload keeps the class and runs its block again.
  def test_reload_reaches_a_builder_constant_through_another_file
    rows = builder_run("builder_constant_subclass_test.rb")
    assert_equal ["killed"], rows["reload"]["BuilderPoint#one?"].uniq
    assert_equal ["survived"], rows["reload"]["BuilderPoint#weak?"].uniq
    assert_equal rows["redefine"], rows["reload"]
  end

  # #528: AE7. The instance another file holds is still a BuilderPoint, so a
  # test that compares classes does not fail for every mutant.
  def test_reload_keeps_the_class_of_a_builder_constant
    rows = builder_run("builder_constant_identity_test.rb")
    assert_equal ["survived"], rows["reload"]["BuilderPoint#one?"].uniq
    assert_equal ["survived"], rows["reload"]["BuilderPoint#weak?"].uniq
    assert_equal rows["redefine"], rows["reload"]
  end

  # #528: AE9. A block that renames and wraps a method would make it call
  # itself on a second run, so reload keeps the class, does not run the block,
  # and marks its methods unplaceable. Redefine places them.
  def test_reload_marks_a_block_it_cannot_run_again_unplaceable
    reload = run_strategy("reload", sources: %w[builder_alias_block.rb], test: "builder_alias_block_test.rb")
    assert_equal ["unplaceable"], reload.fetch("AliasPoint#x").uniq
    assert_equal ["unplaceable"], reload.fetch("AliasPoint#weak?").uniq
    redefine = run_strategy("redefine", sources: %w[builder_alias_block.rb], test: "builder_alias_block_test.rb")
    assert_includes redefine.fetch("AliasPoint#x"), "killed"
    assert_includes redefine.fetch("AliasPoint#weak?"), "survived"
  end

  # #528, P1 of the self-check: a `class ReopenedPoint` statement after the
  # assignment wraps the accessor. A kept class would run that wrap a second
  # time, so `x` would call itself and every mutant would be killed falsely.
  # Reload builds the class again instead, and agrees with redefine.
  def test_reload_does_not_keep_a_builder_constant_a_class_statement_wraps
    rows = %w[redefine reload].to_h do |strategy|
      [strategy, run_strategy(strategy, sources: %w[builder_reopened_alias.rb], test: "builder_reopened_alias_test.rb")]
    end
    assert_includes rows["reload"].fetch("ReopenedPoint#x"), "killed"
    assert_equal ["survived"], rows["reload"].fetch("ReopenedPoint#weak?").uniq
    assert_equal rows["redefine"], rows["reload"]
  end


  # #533, R11, test the rule: a superclass that can name a class the file
  # builds again keeps its text (the same String comes back); any other call
  # superclass is wrapped as before.
  STALE_SUPERCLASSES = {
    "base = Struct.new(:v)\nclass Q < Class.new(base)\nend\n" => :as_written,
    "base = Struct.new(:v)\nclass Q < base.itself\nend\n" => :as_written,
    "class Q < Class.new(@base)\nend\n" => :as_written,
    "class Q < Class.new($base)\nend\n" => :as_written,
    "class Q < Class.new($base ||= Object)\nend\n" => :as_written,
    "class Q < Class.new(@base = make)\nend\n" => :as_written,
    "class Q < Class.new(@@base)\nend\n" => :as_written,
    "base = Struct.new(:v)\nclass Q < Class.new { base }\nend\n" => :as_written,
    "fields = %i[x]\nclass Q < Struct.new(*fields)\nend\n" => :as_written,
    "def self.build_base = Struct.new(:a)\nclass Q < build_base\nend\n" => :as_written,
    "def self.build_base = Struct.new(:a)\nclass Q < (b = build_base)\nend\n" => :as_written,
    "def self.build_base = Struct.new(:a)\nclass Q < Factory.build_base\nend\n" => :as_written,
    "def self.build_base = Struct.new(:a)\nclass Q < Class.new(build_base)\nend\n" => :as_written,
    "Fields = Struct.new(*NAMES)\nclass Q < Class.new(Fields)\nend\n" => :as_written,
    "Fields = build_fields\nclass Q < DelegateClass(Fields)\nend\n" => :as_written,
    "A, Fields = 1, Struct.new(:v)\nclass Q < Class.new(Fields)\nend\n" => :as_written,
    "Fields ||= Struct.new(:v)\nclass Q < Class.new(Fields)\nend\n" => :as_written,
    "Billing::Fields = make\nclass Q < Class.new(Billing::Fields)\nend\n" => :as_written,
    "class Q < Struct.new(:a)\nend\n" => :wrapped,
    "class Q < DelegateClass(IO)\nend\n" => :wrapped,
    "FIELDS = %i[a b].freeze\nclass Q < Struct.new(*FIELDS)\nend\n" => :wrapped,
    "OPTS = { keyword_init: true }\nclass Q < Struct.new(:a, **OPTS)\nend\n" => :wrapped,
    "class Q < Struct.new(:a) { |k| k }\nend\n" => :wrapped,
    "class Q < Struct.new(:a) do\n  def x = @a\nend\nend\n" => :wrapped,
    "class Q < Struct.new(:a)\n  def self.new(*) = super\nend\n" => :wrapped,
    "Fields = Struct.new(:v)\nclass Q < Class.new(Fields)\nend\n" => :wrapped,
    "class Fields; end\nclass Q < Class.new(Fields)\nend\n" => :wrapped
  }.freeze

  def test_a_superclass_that_can_name_a_rebuilt_class_keeps_its_text
    STALE_SUPERCLASSES.each do |code, expected|
      rewritten = Mutineer::JobPlan.keep_live_superclasses(code)
      if expected == :as_written
        refute_includes rewritten, "kept_superclass", code
      else
        assert_includes rewritten, "kept_superclass", code
        refute Mutineer::Parser.invalid?(rewritten), rewritten
      end
    end
    # A file with no call superclass and no literal builder constant is the same String.
    STALE_SUPERCLASSES.each_key do |code|
      next unless code.start_with?("base = ", "fields = ", "def ", "class Q < Class.new(@", "class Q < Class.new($")

      assert_same code, Mutineer::JobPlan.keep_live_superclasses(code), code
    end
  end

  # #533: AE11. A superclass that reads a local, a method of the file, or a
  # constant the file builds again, keeps its text, so a reload errors visibly
  # with "superclass mismatch" instead of keeping a stale parent.
  def test_reload_errors_on_a_superclass_that_can_name_a_rebuilt_class
    %w[stale_superclass_local stale_superclass_method stale_superclass_constant].each do |name|
      doc = run_report("reload", sources: ["#{name}.rb"], test: "#{name}_test.rb")
      assert_equal ["error"], doc["rows"].values.flatten.uniq, name
      assert(doc["details"].all? { |detail| detail.include?("superclass mismatch") }, doc["details"].inspect)
    end
  end

  # #533: AE13, its first example. Reload keeps LiteralFields (#528), so
  # LiteralRow keeps the right parent, and the rows equal the redefine rows.
  def test_reload_scores_a_superclass_that_reads_a_kept_builder_constant
    %w[stale_superclass_literal_test.rb stale_superclass_literal_identity_test.rb].each do |test|
      rows = %w[reload redefine].to_h do |strategy|
        [strategy, run_strategy(strategy, sources: %w[stale_superclass_literal.rb], test: test)]
      end
      assert_equal rows["redefine"], rows["reload"], test
    end
    rows = run_strategy("reload", sources: %w[stale_superclass_literal.rb], test: "stale_superclass_literal_test.rb")
    assert_equal ["killed"], rows["LiteralFields#total"].uniq
    assert_equal ["killed"], rows["LiteralRow#three?"].uniq
    assert_equal ["survived"], rows["LiteralRow#weak?"].uniq
  end

end
