# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

class ProjectTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/calculator.rb", __dir__)

  def with_source(source)
    Tempfile.create(["snippet", ".rb"]) do |f|
      f.write(source)
      f.flush
      yield f.path
    end
  end

  def test_discover_fixture_has_six_subjects
    assert_equal 6, Mutineer::Project.discover([FIXTURE]).size
  end

  def test_discover_instance_methods_with_namespace
    with_source("class Calc\n  def a; end\n  def b; end\nend\n") do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal 2, subjects.size
      assert(subjects.all? { |s| s.namespace == ["Calc"] && s.singleton == false })
      assert_equal %i[a b], subjects.map(&:name)
    end
  end

  def test_discover_singleton_method
    with_source("class Calc\n  def self.foo; end\nend\n") do |path|
      s = Mutineer::Project.discover([path]).first
      assert s.singleton
    end
  end

  def test_discover_singleton_class_block_methods_are_singleton
    with_source("class Calc\n  class << self\n    def foo; end\n    def bar; end\n  end\nend\n") do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %i[foo bar], subjects.map(&:name)
      assert(subjects.all? { |s| s.singleton && s.namespace == ["Calc"] })
    end
  end

  def test_discover_bareword_module_function_methods_are_singleton
    with_source("module M\n  module_function\n  def a; end\n  def b; end\nend\n") do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %i[a b], subjects.map(&:name)
      assert(subjects.all?(&:singleton), "module_function methods should be singleton (#20)")
    end
  end

  def test_discover_bareword_visibility_ends_module_function_mode
    src = <<~RUBY
      module M
        module_function
        def a; end
        public
        def b; end
        module_function
        def c; end
        private
        def d; end
      end
    RUBY
    with_source(src) do |path|
      singleton = Mutineer::Project.discover([path]).to_h { |s| [s.name, s.singleton] }
      assert_equal({ a: true, b: false, c: true, d: false }, singleton)
    end
  end

  def test_discover_visibility_call_in_nested_scope_keeps_module_function_mode
    src = <<~RUBY
      module M
        module_function
        class << self
          private
          def h; end
        end
        def b; end
      end
      module N
        module_function
        def z
          public
        end
        def b; end
      end
    RUBY
    with_source(src) do |path|
      singleton = Mutineer::Project.discover([path]).to_h { |s| [s.qualified_name, s.singleton] }
      assert_equal({ "M.h" => true, "M.b" => true, "N.z" => true, "N.b" => true }, singleton)
    end
  end

  def test_discover_visibility_call_in_a_block_ends_module_function_mode
    src = <<~RUBY
      module M
        module_function
        [1].each { public }
        def b; end
      end
    RUBY
    with_source(src) do |path|
      assert_equal [false], Mutineer::Project.discover([path]).map(&:singleton)
    end
  end

  def test_discover_module_function_symbol_list_marks_named_methods
    # naming call appears AFTER the defs — promotion must be order-independent.
    with_source("module M\n  def a; end\n  def b; end\n  module_function :a\nend\n") do |path|
      subjects = Mutineer::Project.discover([path])
      a = subjects.find { |s| s.name == :a }
      b = subjects.find { |s| s.name == :b }
      assert a.singleton, "module_function :a should be singleton (#20)"
      refute b.singleton, "b was not named by module_function"
    end
  end

  # #98: a named module_function promotes only its own module's methods.
  def test_discover_module_function_symbol_does_not_promote_unrelated_class_method
    src = "module AuditHelper\n  def compute(a, b); a + b; end\n  module_function :compute\nend\n" \
          "class AuditCalculator\n  def compute(a, b); a + b; end\nend\n"
    with_source(src) do |path|
      names = Mutineer::Project.discover([path]).map(&:qualified_name)
      assert_equal %w[AuditHelper.compute AuditCalculator#compute], names
    end
  end

  def test_discover_module_function_symbol_scoped_to_sibling_module
    src = "module A\n  def x; end\n  module_function :x\nend\nmodule B\n  def x; end\nend\n"
    with_source(src) do |path|
      assert_equal %w[A.x B#x], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  def test_discover_inline_module_function_def_does_not_promote_nested_class
    src = "module A\n  module_function def y; end\n  class C\n    def y; end\n  end\nend\n"
    with_source(src) do |path|
      assert_equal %w[A.y A::C#y], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  # Joined namespaces make the compact and nested spellings of one module match:
  # a def in one form is promoted by module_function called from the other.
  def test_discover_module_function_matches_compact_and_nested_namespaces
    compact_def = "module A::B\n  def z; end\nend\nmodule A\n  module B\n    module_function :z\n  end\nend\n"
    with_source(compact_def) do |path|
      assert_equal %w[A::B.z], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
    nested_def = "module A\n  module B\n    def w; end\n  end\nend\nmodule A::B\n  module_function :w\nend\n"
    with_source(nested_def) do |path|
      assert_equal %w[A::B.w], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  def test_discover_module_function_in_reopened_module_promotes_earlier_def
    src = "module M\n  def m; end\nend\nclass K\n  def m; end\nend\nmodule M\n  module_function :m\nend\n"
    with_source(src) do |path|
      assert_equal %w[M.m K#m], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  # `module ::X` inside another module reopens the top-level X, so its namespace
  # restarts at X — for subject names and for module_function scoping alike.
  def test_discover_root_anchored_reopen_restarts_the_namespace
    src = "module Root\n  def compute; end\nend\nmodule Outer\n  module ::Root\n    module_function :compute\n    def extra; end\n  end\n  class ::Solo\n    def x; end\n  end\nend\n"
    with_source(src) do |path|
      assert_equal %w[Root.compute Root#extra Solo#x], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  # The expected name follows discovery's static naming (enclosing namespace +
  # compact path). Ruby may resolve Outer lexically to a top-level constant; a
  # static walk cannot tell, so this pins scoping, not constant resolution.
  def test_discover_module_function_in_compact_module_nested_in_another
    src = "module A\n  module Outer::Inner\n    def v; end\n    module_function :v\n  end\nend\n"
    with_source(src) do |path|
      assert_equal %w[A::Outer::Inner.v], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  def test_discover_module_function_does_not_leak_into_nested_class
    with_source("module M\n  module_function\n  def a; end\n  class Inner\n    def b; end\n  end\nend\n") do |path|
      subjects = Mutineer::Project.discover([path])
      assert subjects.find { |s| s.name == :a }.singleton
      refute subjects.find { |s| s.name == :b }.singleton, "nested class method must not inherit module_function"
    end
  end

  def test_discover_skips_singleton_class_of_other_object
    # `class << other` can't be represented against the namespace -> not emitted.
    with_source("class Calc\n  other = Object.new\n  class << other\n    def skipme; end\n  end\n  def keep; end\nend\n") do |path|
      names = Mutineer::Project.discover([path]).map(&:name)
      assert_equal %i[keep], names
    end
  end

  def test_discover_data_define_and_struct_new_blocks_own_their_methods
    src = <<~RUBY
      Monitoring = Data.define(:a) do
        def self.groups(g) = g
      end
      class ReleaseApp
        Argo = Data.define(:url) do
          def self.from_config(config) = new(url: config)
          def host = url
          class Inner
            def m; end
          end
        end
        Pair = Struct.new(:a, :b) do
          def sum = a + b
        end
        Other = build do
          def n; end
        end
      end
      ReleaseApp::Gate = Struct.new(:open) do
        def open? = open
      end
    RUBY
    with_source(src) do |path|
      names = Mutineer::Project.discover([path]).map(&:qualified_name)
      assert_equal %w[Monitoring.groups ReleaseApp::Argo.from_config ReleaseApp::Argo#host
                      ReleaseApp::Inner#m ReleaseApp::Pair#sum ReleaseApp#n ReleaseApp::Gate#open?], names
    end
  end

  def test_discover_names_a_nested_class_new_after_its_own_constant
    src = <<~RUBY
      module Host
        Argo = Data.define(:url) do
          Other = Class.new do
            def extra = url * 2
          end
          def host = url
          helper = Module.new do
            def anon; end
          end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Host::Other#extra Host::Argo#host Host#anon], subjects.map(&:qualified_name)
      assert_equal [false, false, true], subjects.map(&:owner_unknown)
    end
  end

  def test_discover_unwraps_parentheses_and_begin_and_names_or_and_and_writes
    src = <<~RUBY
      Point = (Data.define(:x) do
        def a; end
      end)
      Wrapped = begin
        Data.define(:x) do
          def b; end
        end
      end
      OrA ||= Data.define(:x) do
        def c; end
      end
      AndA &&= Struct.new(:x) do
        def d; end
      end
      Host::OrB ||= Struct.new(:x) do
        def e; end
      end
      Host::AndB &&= Struct.new(:x) do
        def f; end
      end
      Sum += Struct.new(:x) do
        def g; end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Point#a Wrapped#b OrA#c AndA#d Host::OrB#e Host::AndB#f #g], subjects.map(&:qualified_name)
      assert_equal [false] * 6 + [true], subjects.map(&:owner_unknown)
    end
  end

  def test_discover_resolves_a_builder_constant_path_the_way_the_assignment_does
    src = <<~RUBY
      module Admin
        User::Permission = Data.define(:r) do
          def allow? = r
        end
        ::Root::Gate = Struct.new(:o) do
          def root? = o
        end
      end
      class ReleaseApp
        self::Gate = Struct.new(:open) do
          def open? = open
          self::Latch = Struct.new(:o) do
            def shut? = o
          end
        end
        ReleaseApp::Also = Struct.new(:open) do
          def also? = open
        end
        helper = Class.new do
          self::Lost = Struct.new(:o) do
            def lost? = o
          end
        end
      end
      Top::Path = Data.define(:x) do
        def top? = x
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[User::Permission#allow? Root::Gate#root? ReleaseApp::Gate#open? ReleaseApp::Gate::Latch#shut?
                      ReleaseApp::Also#also? self::Lost#lost? Top::Path#top?], subjects.map(&:qualified_name)
      assert_equal [true, false, false, false, true, true, false], subjects.map(&:owner_unknown)
    end
  end

  def test_discover_names_a_builder_in_class_self_on_the_singleton_class
    src = <<~RUBY
      class App
        class << self
          Point = Data.define(:x) do
            def m = x * 2
            def self.build = new(x: 1)
            Inner = Class.new do
              def n; end
            end
          end
          def after; end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[#<Class:App>::Point#m #<Class:App>::Point.build #<Class:App>::Inner#n App.after],
                   subjects.map(&:qualified_name)
      assert_equal [true, true, true, false], subjects.map(&:owner_unknown)
    end
  end

  def test_discover_nested_classes
    with_source("class Outer\n  class Inner\n    def m; end\n  end\nend\n") do |path|
      s = Mutineer::Project.discover([path]).first
      assert_equal %w[Outer Inner], s.namespace
    end
  end

  def test_discover_module_wrapped_class
    with_source("module M\n  class C\n    def m; end\n  end\nend\n") do |path|
      s = Mutineer::Project.discover([path]).first
      assert_equal %w[M C], s.namespace
    end
  end

  def test_discover_compact_constant_path
    with_source("class Foo::Bar\n  def m; end\nend\n") do |path|
      s = Mutineer::Project.discover([path]).first
      assert_equal %w[Foo::Bar], s.namespace
    end
  end

  def test_only_filter_matches_one
    subjects = Mutineer::Project.discover([FIXTURE], only: "Calculator#add")
    assert_equal 1, subjects.size
    assert_equal :add, subjects.first.name
  end

  def test_only_filter_no_match_returns_empty
    assert_empty Mutineer::Project.discover([FIXTURE], only: "UnknownClass#foo")
  end

  def test_empty_file_returns_empty
    with_source("") do |path|
      assert_empty Mutineer::Project.discover([path])
    end
  end
end
