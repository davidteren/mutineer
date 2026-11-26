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

  # A nested def records the subject of the def whose body holds it, so the
  # redefine strategy can load each enclosing method too (#290).
  def test_discover_links_a_nested_def_to_its_enclosing_def
    src = "class K\n  def a\n    def b\n      def c; end\n    end\n    def d; end\n  end\n  def e; end\nend\n"
    with_source(src) do |path|
      a, b, c, d, e = Mutineer::Project.discover([path]).sort_by(&:name)
      assert_same b, c.enclosing_subject
      assert_same a, b.enclosing_subject
      assert_same a, d.enclosing_subject
      assert_nil a.enclosing_subject
      assert_nil e.enclosing_subject
    end
  end

  # A def in a builder block inside a method still links to that method, and
  # its owner is unknown, so redefine never reaches the enclosing load (#290).
  def test_discover_links_a_def_in_a_builder_block_to_its_enclosing_def
    with_source("class K\n  def a\n    Class.new do\n      def b; end\n    end\n  end\nend\n") do |path|
      a, b = Mutineer::Project.discover([path]).sort_by(&:name)
      assert_same a, b.enclosing_subject
      assert b.unplaceable?("redefine")
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

  # #252: ActiveSupport::Concern evaluates a `class_methods` block in the
  # concern's ClassMethods, so its defs belong there. `self.class_methods` is the same call.
  def test_discover_names_class_methods_block_defs_on_the_concern_class_methods
    src = <<~RUBY
      module Billing
        extend ActiveSupport::Concern
        class_methods do
          def rate(x) = x * 2
        end
        def total; end
      end
      module Order::ReleasePolicy
        extend ::ActiveSupport::Concern
        class_methods do
          def due?(d) = d > 1
        end
      end
      module Shop
        module Pricing
          extend ActiveSupport::Concern
          self.class_methods do
            def round(x) = x
          end
        end
        helper = Module.new do
          extend ActiveSupport::Concern
          class_methods do
            def anon; end
          end
        end
      end
      Tagged = Module.new do
        extend ActiveSupport::Concern
        class_methods do
          def tag; end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Billing::ClassMethods#rate Billing#total Order::ReleasePolicy::ClassMethods#due?
                      Shop::Pricing::ClassMethods#round Shop#anon Tagged::ClassMethods#tag],
                   subjects.map(&:qualified_name)
      assert_equal ["::Billing::ClassMethods", nil, "::Order::ReleasePolicy::ClassMethods",
                    "::Shop::Pricing::ClassMethods", nil, "::Tagged::ClassMethods"], subjects.map(&:block_owner)
      assert_equal [["Billing"], ["Billing"], ["Order::ReleasePolicy"], %w[Shop Pricing], ["Shop"], []],
                   subjects.map(&:lexical)
      # An unassigned Module.new has no name, so its ClassMethods has none either.
      assert_equal %w[Shop#anon], subjects.select(&:owner_unknown).map(&:qualified_name)
    end
  end

  # ActiveSupport runs an `included` or `prepended` block in each includer, so
  # its defs keep their names but have their owner unknown.
  def test_discover_marks_included_and_prepended_block_defs_owner_unknown
    src = <<~RUBY
      module Billing
        extend ActiveSupport::Concern
        included do
          def tag; end
          Kind = Struct.new(:a) do
            def b; end
          end
        end
        self.prepended do
          def wrap; end
        end
        included(Object)
        def total; end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Billing#tag Billing::Kind#b Billing#wrap Billing#total], subjects.map(&:qualified_name)
      assert_equal [true, false, true, false], subjects.map(&:owner_unknown)
      # #256: reload does not run the block again, so everything in it is marked,
      # the named Struct's def included.
      assert_equal [true, true, true, false], subjects.map(&:hook_block)
    end
  end

  # #297: reload can place a def that sits directly in a plain `included` or
  # `prepended` block, in its `class << self` too. Each such subject carries
  # the hook call that discovery found.
  def test_discover_sets_the_hook_call_for_placeable_hook_defs
    src = <<~RUBY
      module Billing
        extend ActiveSupport::Concern
        included do
          def a; end
          def self.b; end
          class << self
            def c; end
          end
          private def d; end
        end
        self.prepended do
          def e; end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Billing#a Billing.b Billing.c Billing#d Billing#e], subjects.map(&:qualified_name)
      assert_equal [3, 3, 3, 3, 11], subjects.map { |s| s.reload_hook_call&.location&.start_line }
      assert(subjects.none? { |s| s.unplaceable?("reload") })
      assert(subjects.all? { |s| s.unplaceable?("redefine") })
    end
  end

  # #297: a def that is not directly in the hook block stays unplaceable.
  def test_discover_leaves_nested_hook_defs_unplaceable
    src = <<~RUBY
      module Billing
        extend ActiveSupport::Concern
        included do
          class Inner
            def a; end
          end
          Kind = Struct.new(:a) do
            def b; end
          end
          Anon = Class.new do
            def f; end
          end
          def outer
            def c; end
          end
          [1].each do
            def d; end
          end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path]).to_h { |s| [s.name, s] }
      %i[a b f c d].each do |name|
        assert subjects.fetch(name).hook_block, name
        assert_nil subjects.fetch(name).reload_hook_call, name
      end
      refute_nil subjects.fetch(:outer).reload_hook_call
    end
  end

  # An extracted def does not retain a receiver bound by the original block.
  def test_discover_leaves_hook_local_receivers_unplaceable
    src = <<~RUBY
      module BoundHooks
        extend ActiveSupport::Concern
        included do |base|
          def base.tag = 1
          receiver = self
          def receiver.other = 2
          def self.safe = 3
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path]).to_h { |s| [s.name, s] }
      %i[tag other].each do |name|
        assert subjects.fetch(name).unplaceable?("reload"), name
        assert_nil subjects.fetch(name).reload_hook_call, name
      end
      refute subjects.fetch(:safe).unplaceable?("reload")
    end
  end

  # Ruby reports only the definition's file and line. Equal names on one line
  # cannot identify which concern supplied an existing host's method.
  def test_discover_leaves_ambiguous_same_line_hook_defs_unplaceable
    src = "module First; extend ActiveSupport::Concern; included do; def total = 1; end; end; " \
          "module Second; extend ActiveSupport::Concern; included do; def total = 2; end; end\n"
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[First#total Second#total], subjects.map(&:qualified_name)
      assert(subjects.all? { |subject| subject.unplaceable?("reload") })
      selected = Mutineer::Project.discover([path], only: "First#total")
      assert selected.first.unplaceable?("reload"), "--only must not hide the other definition"
    end
  end

  def test_discover_leaves_same_line_instance_and_singleton_hook_defs_unplaceable
    src = "module TwoDefs; extend ActiveSupport::Concern; included do; def total = 1; def self.total = 2; end; end\n"
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[TwoDefs#total TwoDefs.total], subjects.map(&:qualified_name)
      assert(subjects.all? { |subject| subject.unplaceable?("reload") })
    end
  end

  def test_discover_leaves_a_hook_def_ambiguous_with_an_ordinary_def_unplaceable
    src = "module Hook; extend ActiveSupport::Concern; included do; def total = 1; end; end; " \
          "class Ordinary; def total = 2; end\n"
    with_source(src) do |path|
      hook, ordinary = Mutineer::Project.discover([path])
      assert hook.unplaceable?("reload")
      refute ordinary.unplaceable?("reload")
    end
  end

  def test_discover_keeps_different_same_line_hook_defs_placeable
    src = "module TwoDefs; extend ActiveSupport::Concern; included do; def a = 1; def b = 2; end; end\n"
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[TwoDefs#a TwoDefs#b], subjects.map(&:qualified_name)
      assert(subjects.none? { |subject| subject.unplaceable?("reload") })
    end
  end

  # Method creators that Ruby maps to the same file and line are ambiguous
  # even when their definitions are absent from SubjectVisitor's output.
  def assert_hook_creator_ambiguity(creator, name: :tag, unplaceable: true)
    definition = name.to_s.end_with?("=") ? "def #{name}(value); 1; end" : "def #{name} = 1"
    src = "module HookCollision; extend ActiveSupport::Concern; included do; #{definition}; #{creator}; end; end\n"
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal ["HookCollision##{name}"], subjects.map(&:qualified_name), creator
      assert_equal unplaceable, subjects.first.unplaceable?("reload"), creator
    end
  end

  def test_discover_counts_defs_inside_an_unselected_singleton_class
    assert_hook_creator_ambiguity("class << TARGET; def tag = 2; end")
  end

  def test_discover_counts_builtin_method_creators_on_the_hook_line
    ["TARGET.singleton_class.define_method(:tag) { 2 }",
     'TARGET.define_singleton_method("tag") { 2 }',
     "TARGET.singleton_class.attr_reader(:tag)",
     'TARGET.singleton_class.attr_accessor("tag")',
     "TARGET.singleton_class.attr(:tag)"].each { |creator| assert_hook_creator_ambiguity(creator) }
    ["TARGET.singleton_class.attr_writer(:tag)",
     'TARGET.singleton_class.attr_accessor("tag")',
     "TARGET.singleton_class.attr(:tag, true)"].each do |creator|
      assert_hook_creator_ambiguity(creator, name: :tag=)
    end
  end

  def test_discover_blocks_unknown_creator_names_only_on_the_hook_line
    ["TARGET.singleton_class.define_method(method_name) { 2 }",
     "TARGET.define_singleton_method(method_name) { 2 }",
     "TARGET.singleton_class.attr_reader(method_name)",
     "TARGET.singleton_class.attr_writer(method_name)",
     "TARGET.singleton_class.attr_accessor(method_name)",
     "TARGET.singleton_class.attr(method_name)"].each { |creator| assert_hook_creator_ambiguity(creator) }
    assert_hook_creator_ambiguity("TARGET.singleton_class.attr(:tag, writable)", name: :tag=)
  end

  def test_discover_keeps_nonmatching_creator_names_placeable
    assert_hook_creator_ambiguity("TARGET.singleton_class.define_method(:other) { 2 }", unplaceable: false)
    assert_hook_creator_ambiguity("TARGET.singleton_class.attr_writer(:tag)", unplaceable: false)
    assert_hook_creator_ambiguity("TARGET.singleton_class.attr(:tag, false)", name: :tag=, unplaceable: false)
  end

  def test_discover_uses_the_method_creators_runtime_source_line
    ["TARGET.singleton_class\n .define_method(\n :tag\n ) { 2 }; def tag = 1",
     "TARGET\n .singleton_class\n .attr_reader(:tag); def tag = 1"].each do |body|
      src = "module HookCollision\n extend ActiveSupport::Concern\n included do\n #{body}\n end\nend\n"
      with_source(src) do |path|
        subject = Mutineer::Project.discover([path]).first
        assert subject.unplaceable?("reload"), body
      end
    end
  end

  def test_discover_does_not_treat_a_multiline_receiver_as_the_creation_line
    ["def tag = 1; TARGET.singleton_class\n .define_method(:tag) { 2 }",
     "def tag = 1; TARGET\n .singleton_class\n .attr_reader(:tag)",
     "def tag = 1\n TARGET.singleton_class.attr_reader(method_name)"].each do |body|
      src = "module HookCollision\n extend ActiveSupport::Concern\n included do\n #{body}\n end\nend\n"
      with_source(src) do |path|
        subject = Mutineer::Project.discover([path]).first
        refute subject.unplaceable?("reload"), body
      end
    end
  end

  def assert_hook_callable_body_ambiguity(body, unplaceable: true)
    src = "module HookCollision\n extend ActiveSupport::Concern\n included do\n#{body}\n end\nend\n"
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal ["HookCollision#tag"], subjects.map(&:qualified_name), body
      assert_equal unplaceable, subjects.first.unplaceable?("reload"), body
    end
  end

  def test_discover_uses_inline_positional_and_block_pass_callable_lines
    ["TARGET.define_singleton_method(:tag,\n -> { 2 }); def tag = 1",
     "TARGET.define_singleton_method(:tag,\n &-> { 2 }); def tag = 1",
     "TARGET.define_singleton_method(:tag,\n proc { 2 }); def tag = 1"].each do |body|
      assert_hook_callable_body_ambiguity(body)
    end
  end

  def test_discover_counts_stored_callable_body_lines_for_indirect_creators
    ["body = -> { 2 }; def tag = 1\n TARGET.define_singleton_method(:tag, body)",
     "body = proc { 2 }; def tag = 1\n TARGET.define_singleton_method(:tag, &body)",
     "body = -> { 2 }; def tag = 1\n method_name = :tag\n TARGET.define_singleton_method(method_name, body)"].each do |body|
      assert_hook_callable_body_ambiguity(body)
    end
  end

  def test_discover_keeps_noncolliding_callable_sources_placeable
    ["body = -> { 2 }\n def tag = 1\n TARGET.define_singleton_method(:tag, body)",
     "body = -> { 2 }; def tag = 1\n TARGET.define_singleton_method(:other, body)",
     "body = proc { 2 }\n TARGET.define_singleton_method(:tag, &body); def tag = 1",
     "TARGET.define_singleton_method(:tag,\n -> { 2 }\n ) { 3 }; def tag = 1"].each do |body|
      assert_hook_callable_body_ambiguity(body, unplaceable: false)
    end
  end

  def test_discover_counts_a_reused_hook_container_as_a_possible_method_body
    src = <<~RUBY
      module ContainerReuse
        extend ActiveSupport::Concern
        included do; def tag = 1 unless self.equal?(TARGET)
          body = ContainerReuse.instance_variable_get(:@_included_block)
          TARGET.define_singleton_method(:tag, body) unless self.equal?(TARGET)
          2
        end
      end
    RUBY
    with_source(src) do |path|
      subject = Mutineer::Project.discover([path]).first
      assert subject.unplaceable?("reload")
    end
  end

  def test_discover_keeps_ordinary_one_line_hooks_placeable
    ["", "body = -> { 2 }\n TARGET.define_singleton_method(:other, body)"].each do |body|
      src = "module HookCollision\n extend ActiveSupport::Concern\n included do; def tag = 1\n#{body}\n end\nend\n"
      with_source(src) do |path|
        subject = Mutineer::Project.discover([path]).first
        refute subject.unplaceable?("reload")
      end
    end
  end

  # #297: an alias keeps the original body, so a block that aliases anything
  # keeps every def in it unplaceable.
  def test_an_alias_in_the_hook_block_makes_every_def_unplaceable
    src = <<~RUBY
      module Billing
        extend ActiveSupport::Concern
        included do
          def tag; end
          def other; end
          alias_method :copy, :tag
        end
      end
      module Shipping
        extend ActiveSupport::Concern
        included do
          def tag; end
          alias twin tag
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal 3, subjects.size
      assert(subjects.all? { |s| s.hook_block && s.reload_hook_call.nil? })
    end
  end

  # #297: the added statement must run exactly when the hook call runs, so
  # only a hook call on a plain path from the top of the file is placeable.
  def test_discover_requires_a_hook_call_on_a_plain_path
    src = <<~RUBY
      module A
        extend ActiveSupport::Concern
        x = included do
          def a; end
        end
      end
      module B
        extend ActiveSupport::Concern
        x =
          included do
            def b; end
          end
      end
      module C
        extend ActiveSupport::Concern
        foo(included do
          def c; end
        end)
      end
      module D
        extend ActiveSupport::Concern
        included do
          def d; end
        end if true
      end
      module G
        extend ActiveSupport::Concern
        included do
          def g; end
        end
      end unless defined?(G)
      defined?(H) || module H
        extend ActiveSupport::Concern
        included do
          def h; end
        end
      end
      module I
        extend ActiveSupport::Concern
        case 1
        in Integer then included do
          def i; end
        end
        end
      end
      module J
        extend ActiveSupport::Concern
        def self.setup
          included do
            def j; end
          end
        end
      end
      module K
        extend ActiveSupport::Concern
        class << self
          included do
            def k; end
          end
        end
      end
      module L
        extend ActiveSupport::Concern
        included do
          def l; end
          module_function :l
        end
      end
      module M
        extend ActiveSupport::Concern; included do
          def m; end
        end
      end
      module N
        extend ActiveSupport::Concern
        included do
          def n; end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path]).to_h { |s| [s.name, s] }
      %i[a b c d g h i j k l].each { |name| assert_nil subjects.fetch(name).reload_hook_call, name }
      refute_nil subjects.fetch(:m).reload_hook_call
      refute_nil subjects.fetch(:n).reload_hook_call
    end
  end

  # #297: a file that can return early may never reach its hook call.
  def test_a_top_level_return_makes_the_file_unplaceable
    src = <<~RUBY
      return if defined?(R)

      module R
        extend ActiveSupport::Concern
        included do
          def r; end
        end
      end
    RUBY
    with_source(src) do |path|
      subject = Mutineer::Project.discover([path]).first
      assert subject.hook_block
      assert_nil subject.reload_hook_call
    end
  end

  # #297: the block ran once with the original def, so a def the block itself
  # calls outside a def body keeps that result and stays unplaceable. A symbol
  # argument calls by name later, so it stays placeable.
  def test_a_def_the_block_uses_stays_unplaceable
    src = <<~RUBY
      module Billing
        extend ActiveSupport::Concern
        included do
          def self.columns = %i[a]
          searchable columns
          def cb; end
          register method(:cb)
          def compute; end
          %i[a].each { register(compute) }
          def normalize; end
          before_save { normalize }
          def saved; end
          before_save :saved
          def sent = 1
          register send(:sent)
          def pub = 1
          register public_send("pub")
          def raw = 1
          register __send__(:raw)
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path]).to_h { |s| [s.name, s] }
      %i[columns cb compute normalize sent pub raw].each do |name|
        assert_nil subjects.fetch(name).reload_hook_call, name
      end
      refute_nil subjects.fetch(:saved).reload_hook_call
    end
  end

  # #297: a name `send` computes at runtime may be any def in the block, so
  # the block places nothing.
  def test_a_runtime_send_name_leaves_the_block_unplaceable
    src = "module Billing; extend ActiveSupport::Concern; included do; def a = 1; register send(pick); end; end\n"
    with_source(src) do |path|
      assert_nil Mutineer::Project.discover([path]).first.reload_hook_call
    end
  end

  # #256: only a concern's `included` or `prepended` block is one ActiveSupport
  # runs once. A `class_methods` block, or another library's `included`, is not.
  def test_discover_marks_only_concern_included_and_prepended_blocks_as_hook_blocks
    src = <<~RUBY
      module Billing
        extend ActiveSupport::Concern
        class_methods do
          def rate; end
        end
      end
      module Plugin
        included do
          def hook; end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Billing::ClassMethods#rate Plugin#hook], subjects.map(&:qualified_name)
      assert_equal [false, false], subjects.map(&:hook_block)
    end
  end

  # Another library can define `class_methods` or `included` and run the block
  # in the module itself. Only a module that extended ActiveSupport::Concern
  # earlier in the file gets ClassMethods names; any other such block keeps its
  # names and is unplaceable, so redefine never loads a mutant onto a guess.
  def test_discover_marks_blocks_of_a_module_not_known_as_a_concern_owner_unknown
    src = <<~RUBY
      module Prices
        extend PriceDSL
        class_methods do
          def total(x) = x * 2
        end
        included do
          def tag; end
        end
        extend ActiveSupport::Concern
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Prices#total Prices#tag], subjects.map(&:qualified_name)
      assert(subjects.all? { |s| s.block_owner.nil? && s.owner_unknown })
    end
  end

  # The extend may be `self.extend`, parenthesized or one of several modules. A
  # later body that reopens the concern in the same file, also in compact form,
  # is still the concern; a module nested in it is not one.
  def test_discover_remembers_a_concern_across_bodies_and_extend_forms
    src = <<~RUBY
      module Billing
        self.extend Comparable, ::ActiveSupport::Concern
        module Inner
          class_methods do
            def inner; end
          end
        end
      end
      module Billing
        class_methods do
          def rate; end
        end
      end
      module Ledger
        extend(ActiveSupport::Concern)
        class_methods do
          def post; end
        end
      end
      module Shop
        module Cart
          extend ActiveSupport::Concern
        end
      end
      module Shop::Cart
        class_methods do
          def total; end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Billing::Inner#inner Billing::ClassMethods#rate Ledger::ClassMethods#post
                      Shop::Cart::ClassMethods#total], subjects.map(&:qualified_name)
      assert_equal [true, false, false, false], subjects.map(&:owner_unknown)
    end
  end

  # Only an extend that the module body runs itself counts: one in a def, in
  # `class << self`, in another block or on another receiver does not.
  def test_discover_ignores_a_concern_extend_the_module_body_does_not_run
    src = <<~RUBY
      module Audit
        def setup
          extend ActiveSupport::Concern
        end
        class << self
          extend ActiveSupport::Concern
        end
        Other.class_eval do
          extend ActiveSupport::Concern
        end
        Other.extend ActiveSupport::Concern
        class_methods do
          def rate(x) = x
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Audit#setup Audit#rate], subjects.map(&:qualified_name)
      assert_equal [false, true], subjects.map(&:owner_unknown)
    end
  end

  # In a def, a non-builder block (Rails' `concerning`) or `class << self`, no
  # constant names the ClassMethods the block runs in, so its defs keep their
  # names with their owner unknown. A call with a receiver or arguments is not
  # the Concern DSL, so its block is a plain block.
  def test_discover_marks_class_methods_outside_a_module_body_owner_unknown
    src = <<~RUBY
      module Billing
        extend ActiveSupport::Concern
        def setup
          class_methods do
            def in_def; end
          end
        end
        concerning :Rates do
          class_methods do
            def in_block; end
          end
        end
        class << self
          class_methods do
            def in_singleton; end
          end
        end
        Order.class_methods do
          def with_receiver; end
        end
        class_methods(:x) do
          def with_args; end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Billing#setup Billing#in_def Billing#in_block Billing.in_singleton Billing#with_receiver
                      Billing#with_args], subjects.map(&:qualified_name)
      assert(subjects.none?(&:block_owner))
      assert_equal %w[Billing#in_def Billing#in_block Billing.in_singleton],
                   subjects.select(&:owner_unknown).map(&:qualified_name)
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

  def test_discover_names_a_class_opened_in_class_self_on_the_singleton_class
    src = <<~RUBY
      class App
        class << self
          class Q
            def q1 = 1
            class R
              def r1; end
            end
            X = Class.new do
              def x1; end
            end
            self::S = Class.new do
              def s1; end
            end
            class ::Deep
              def d; end
            end
            ::DeepB = Class.new do
              def e; end
            end
          end
          class ::Top
            def t; end
          end
          P = Data.define do
            module Z
              def z1; end
            end
          end
          module Foo::Mod
            def c; end
            module_function :c
          end
          def after; end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[#<Class:App>::Q#q1 #<Class:App>::Q::R#r1 #<Class:App>::Q::X#x1 #<Class:App>::Q::S#s1 Deep#d
                      DeepB#e Top#t #<Class:App>::Z#z1 Foo::Mod.c App.after], subjects.map(&:qualified_name)
      assert_equal [true] * 9 + [false], subjects.map(&:owner_unknown)
    end
  end

  def test_discover_names_a_class_in_nested_class_self_on_the_inner_singleton_class
    src = <<~RUBY
      class App
        class << self
          class Q
            def q; end
          end
          class << self
            class Q
              def q; end
            end
            P = Data.define do
              class Z
                def z; end
              end
            end
          end
        end
        R = Data.define do
          class << self
            class << self
              class W
                def w; end
              end
            end
          end
        end
      end
    RUBY
    with_source(src) do |path|
      assert_equal %w[#<Class:App>::Q#q #<Class:#<Class:App>>::Q#q #<Class:#<Class:App>>::Z#z
                      #<Class:#<Class:App::R>>::W#w], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  def test_discover_names_class_self_in_a_builder_block_on_the_built_class
    src = <<~RUBY
      class App
        P = Data.define do
          class << self
            class W
              def w; end
            end
            Y = Class.new do
              def y; end
            end
          end
        end
        Class.new do
          class << self
            class W
              def a; end
            end
          end
        end
        Q = Class.new do
          class << self
            P = Data.define do
              class Z
                def z; end
              end
            end
            class Foo::Bar
              def b; end
            end
            class self::S
              def s; end
            end
            ::Top = Class.new do
              def t; end
            end
          end
        end
        class << self
          module M
            def m1; end
            module_function :m1
          end
          N = Module.new do
            def n1; end
            module_function :n1
          end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[#<Class:App::P>::W#w #<Class:App::P>::Y#y #<Class:App::#<anonymous>>::W#a #<Class:App::Q>::Z#z
                      Foo::Bar#b self::S#s Top#t #<Class:App>::M.m1 #<Class:App>::N.n1], subjects.map(&:qualified_name)
      assert(subjects.all?(&:owner_unknown))
    end
  end

  def test_discover_promotes_module_function_only_in_its_own_unknown_owner_body
    src = <<~RUBY
      a = Class.new do
        self::Z = Module.new do
          def c; end
          module_function :c
        end
      end
      b = Class.new do
        self::Z = Module.new do
          def c; end
        end
      end
      class App
        Class.new do
          class << self
            module M
              def c; end
              module_function :c
            end
          end
        end
        Class.new do
          class << self
            module M
              def c; end
            end
          end
        end
      end
    RUBY
    with_source(src) do |path|
      assert_equal %w[self::Z.c self::Z#c #<Class:App::#<anonymous>>::M.c #<Class:App::#<anonymous>>::M#c],
                   Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  # #216: a module opened twice inside `class << self` is one module, so a later
  # `module_function :c` promotes the `c` of the earlier opening.
  def test_discover_module_function_in_reopened_module_under_class_self_promotes_earlier_def
    src = <<~RUBY
      class App
        class << self
          module M
            def c; end
          end
          module M
            module_function :c
          end
        end
      end
    RUBY
    with_source(src) do |path|
      assert_equal %w[#<Class:App>::M.c], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  # #216: a Unicode constant name is a constant name too.
  def test_discover_module_function_in_reopened_module_under_unicode_class_self
    src = "class Å\n  class << self\n    module M\n      def c; end\n    end\n    module M\n      module_function :c\n    end\n  end\nend\n"
    with_source(src) do |path|
      assert_equal %w[#<Class:Å>::M.c], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  # #216: modules that share a short name under different singleton classes stay apart.
  def test_discover_module_function_does_not_cross_modules_sharing_a_name_under_class_self
    src = <<~RUBY
      class A
        class << self
          module Helpers
            def h; end
            module_function :h
          end
        end
      end
      class B
        class << self
          module Helpers
            def h; end
          end
          class << self
            module Helpers
              def h; end
            end
          end
        end
      end
    RUBY
    with_source(src) do |path|
      assert_equal %w[#<Class:A>::Helpers.h #<Class:B>::Helpers#h #<Class:#<Class:B>>::Helpers#h],
                   Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  # #216: `class Foo::Bar` inside `class << self` may not be the top-level Foo::Bar,
  # so a module under its singleton class matches only within its own body. The
  # top-level Foo::Bar, compact or nested, is one class and its openings match.
  def test_discover_module_function_does_not_cross_a_singleton_class_built_on_a_written_path
    src = <<~RUBY
      class App
        class << self
          class Foo::Bar
            class << self
              module M
                def c; end
              end
            end
          end
        end
      end
      class Foo::Bar
        class << self
          module M
            def c; end
            module_function :c, :d
          end
        end
      end
      module Foo
        class Bar
          class << self
            module M
              def d; end
            end
          end
        end
      end
    RUBY
    with_source(src) do |path|
      assert_equal %w[#<Class:Foo::Bar>::M#c #<Class:Foo::Bar>::M.c #<Class:Foo::Bar>::M.d],
                   Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  # #216: `module self::X` in a builder block is under the built class, so it does
  # not match the enclosing module's own X, though both are named the same.
  def test_discover_module_function_does_not_cross_self_path_in_a_builder_block
    src = <<~RUBY
      class App
        class << self
          module M
            Class.new do
              module self::X
                def c; end
              end
            end
            Other.class_eval do
              self::X = Module.new do
                def c; end
              end
            end
            module X
              def c; end
              module_function :c
            end
          end
        end
      end
    RUBY
    with_source(src) do |path|
      assert_equal %w[#<Class:App>::M::X#c #<Class:App>::M::X#c #<Class:App>::M::X.c],
                   Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  # #216: the same holds outside `class << self`, and for a module under the
  # singleton class of such a `self::X`. Openings under one `self` still match.
  # #229: the X is under the built class, Outer::Foo, and redefine cannot reopen it.
  def test_discover_module_function_does_not_cross_self_path_in_a_named_builder_block
    src = <<~RUBY
      module Outer
        Foo = Class.new do
          module self::X
            def c; end
            class << self
              module M
                def d; end
              end
            end
            module N
              def e; end
            end
            module N
              module_function :e
            end
            module A::B
              module_function :f
            end
            module A
              module B
                def f; end
              end
            end
          end
          module self::X
            def g; end
          end
          module self::X
            module_function :g
          end
        end
        module X
          module_function :c
          class << self
            module M
              module_function :d
            end
          end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Outer::Foo::X#c #<Class:Outer::Foo::X>::M#d Outer::Foo::X::N.e Outer::Foo::X::A::B.f
                      Outer::Foo::X.g], subjects.map(&:qualified_name)
      assert_equal [true] * 5, subjects.map(&:owner_unknown)
    end
  end

  # #229: `self` in a block may be another object, so a `self::X` opened or
  # assigned there, and everything in it, has its owner unknown. The name stays on
  # the enclosing namespace. Directly in a class body `self` is that class.
  # #229: in a builder block, `self::X = Module.new` and a later `module self::X`
  # are the same module, so `module_function` in one promotes the other's method.
  def test_discover_module_function_matches_self_path_assigned_and_reopened_in_a_builder_block
    src = <<~RUBY
      module Outer
        Foo = Class.new do
          self::X = Module.new do
            def c; end
          end
          module self::X
            module_function :c
          end
        end
      end
    RUBY
    with_source(src) do |path|
      assert_equal %w[Outer::Foo::X.c], Mutineer::Project.discover([path]).map(&:qualified_name)
    end
  end

  def test_discover_self_path_in_a_block_has_its_owner_unknown
    src = <<~RUBY
      module Outer
        module self::Direct
          def a; end
        end
        configure do
          module self::X
            def c; end
            module N
              def d; end
            end
            Z = Module.new do
              def z; end
            end
          end
          class self::K
            def k; end
          end
          self::Y = Module.new do
            def y; end
          end
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[Outer::Direct#a Outer::X#c Outer::X::N#d Outer::X::Z#z Outer::K#k Outer::Y#y],
                   subjects.map(&:qualified_name)
      assert_equal %w[Outer::Direct#a], subjects.reject(&:owner_unknown).map(&:qualified_name)
    end
  end

  # #216: `class << self` in a def or a `class_eval` block opens the singleton class
  # of whatever `self` is then, so its modules do not match App's own; nor does a
  # `self::X` there. A block inside App's own `class << self` does not change where
  # a module goes, so its M is App's M.
  def test_discover_module_function_does_not_cross_class_self_in_a_def_or_block
    src = <<~RUBY
      class App
        def setup
          class << self
            module M
              def c; end
            end
          end
        end
        Other.class_eval do
          class << self
            module M
              def d; end
            end
          end
          module self::X
            def x; end
          end
          self::Y = Module.new do
            def y; end
          end
        end
        class << self
          module M
            module_function :c, :d, :e
          end
          setup do
            module M
              def e; end
            end
          end
        end
        module X
          module_function :x
        end
        module Y
          module_function :y
        end
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      assert_equal %w[App#setup #<Class:App>::M#c #<Class:App>::M#d App::X#x App::Y#y #<Class:App>::M.e],
                   subjects.map(&:qualified_name)
      # #229: X and Y are under Other at run time, so redefine cannot place them.
      assert_equal %w[App#setup], subjects.reject(&:owner_unknown).map(&:qualified_name)
    end
  end

  def test_discover_promotes_module_function_names_in_a_module_new_block
    src = <<~RUBY
      module Host
        Helpers = Module.new do
          def calc; end
          module_function :calc
        end
        def calc; end
      end
      module Other
        helper = Module.new do
          def calc; end
          module_function :calc
        end
        def calc; end
      end
    RUBY
    with_source(src) do |path|
      assert_equal %w[Host::Helpers.calc Host#calc Other#calc Other#calc],
                   Mutineer::Project.discover([path]).map(&:qualified_name)
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

  # #492: reload keeps a class statement's live superclass, so a def inside the
  # superclass call's block cannot be placed. A def in the class body can.
  def test_a_def_in_a_superclass_block_is_unplaceable_under_reload_only_there
    src = "class X < Struct.new(:a) do\n  def inner; end\nend\n  def outer; end\nend\n" \
          "Y = Struct.new(:b) do\n  def built; end\nend\n"
    with_source(src) do |path|
      by_name = Mutineer::Project.discover([path]).to_h { |s| [s.name, s] }
      assert by_name[:inner].in_superclass_block
      assert by_name[:inner].unplaceable?("reload")
      refute by_name[:outer].in_superclass_block
      refute by_name[:outer].unplaceable?("reload")
      refute by_name[:built].in_superclass_block, "the assignment form reloads its block"
      refute by_name[:built].unplaceable?("reload")
      refute by_name[:built].not_reloaded, "the block runs again"
    end
  end

  # #503, #528: reload keeps the class of every literal builder constant. A
  # block it can run again runs again on that class, so its defs are
  # placeable. A block with a statement it cannot run again is kept and not
  # run, so each def in it is unplaceable under reload (R9). Redefine places
  # both.
  def test_a_def_in_a_kept_block_is_unplaceable_under_reload_only_when_the_block_does_not_run_again
    src = "BaseRow = Struct.new(:v) do\n  def in_block?; end\nend\n" \
          "class Row < BaseRow\n  def three?; end\nend\n" \
          "module Ledger\n  Ledger::Entry = Data.define(:c) do\n    def path_block; end\n  end\n" \
          "  Other = Struct.new(:o) do\n    def other; end\n  end\nend\n" \
          "Aliased = Struct.new(:a) do\n  alias_method :b, :a\n  def aliased; end\nend\n" \
          "class Ledger::Credit < Ledger::Entry\nend\n"
    with_source(src) do |path|
      by_name = Mutineer::Project.discover([path]).to_h { |s| [s.name, s] }
      %i[in_block? path_block other three?].each do |name|
        refute by_name[name].not_reloaded, name
        refute by_name[name].unplaceable?("reload"), name
      end
      assert by_name[:aliased].not_reloaded
      assert by_name[:aliased].unplaceable?("reload")
      refute by_name[:aliased].unplaceable?("redefine")
    end
    # A path write is kept and reopened with no class statement for it, and a
    # builder method's value is not a literal builder, so it is built again.
    src = "Other::Base = Struct.new(:v) do\n  def path_write; end\nend\nclass User < Base\nend\n" \
          "Row2Base = build_base do\n  def built; end\nend\nclass Row2 < Row2Base\nend\n" \
          "Twice = Struct.new(:v) do\n  alias_method :b, :v\n  def twice; end\nend\nTwice = 1\n"
    with_source(src) do |path|
      by_name = Mutineer::Project.discover([path]).to_h { |s| [s.name, s] }
      refute by_name[:path_write].not_reloaded
      refute by_name[:built].not_reloaded
      refute by_name[:twice].not_reloaded, "a name the file writes twice is not kept (R22)"
    end
  end

  # #529, test the rule: a second load does not run the value of a constant
  # `||=`, nor the statements of `unless defined?(X)` or `if !defined?(X)`
  # that define `X`, so each def there is unplaceable under reload only.
  # Names match by their last segment (R2 of the plan), which fails closed.
  NOT_RELOADED_TEXTS = {
    m1: "X ||= Struct.new(:a) do def m1; end end\n",
    m2: "A::X ||= Class.new do def m2; end end\n",
    m3: "X ||= lambda { def m3; end }\n",
    m4: "X = Struct.new(:a) do def m4; end end unless defined?(X)\n",
    m5: "unless defined?(X)\n  class X\n    def m5; end\n  end\nend\n",
    m6: "if !defined?(X)\n  module X\n    def m6; end\n  end\nend\n",
    m7: "if not defined?(::X)\n  ::X = Class.new do def m7; end end\nend\n",
    m8: "unless (defined?(X))\n  X = 1\n  def m8; end\nend\n",
    m9: "unless defined?(X)\n  X ||= 1\n  class Worker\n    def m9; end\n  end\nend\n",
    m10: "unless defined?(B)\n  A, B = 1, 2\n  def m10; end\nend\n",
    m11: "unless defined?(A::X)\n  B::X = 1\n  def m11; end\nend\n"
  }.freeze

  # The guard does not define the tested name, the def is in the `else`
  # branch, the guard is not negated, the write is `&&=`, or the predicate is
  # not `defined?` of a constant: each runs again on a second load.
  RELOADED_TEXTS = {
    n1: "unless defined?(Rails)\n  class Shim\n    def n1; end\n  end\nend\n",
    n2: "unless defined?(X)\n  1\nelse\n  X = 1\n  def n2; end\nend\n",
    n3: "if defined?(X)\n  def n3; end\nend\n",
    n4: "X &&= Struct.new(:a) do def n4; end end\n",
    n5: "unless ready?\n  X = 1\n  def n5; end\nend\n",
    n6: "unless defined?(@x)\n  def n6; end\nend\n"
  }.freeze

  def test_a_def_that_a_second_load_skips_is_unplaceable_under_reload_only
    NOT_RELOADED_TEXTS.each do |name, src|
      with_source(src) do |path|
        subject = Mutineer::Project.discover([path]).find { |s| s.name == name }
        refute_nil subject, src
        assert subject.not_reloaded, src
        assert subject.unplaceable?("reload"), src
        refute subject.unplaceable?("redefine"), src
      end
    end
    RELOADED_TEXTS.each do |name, src|
      with_source(src) do |path|
        subject = Mutineer::Project.discover([path]).find { |s| s.name == name }
        refute_nil subject, src
        refute subject.not_reloaded, src
        refute subject.unplaceable?("reload"), src
      end
    end
  end

  # #504: during a reload the guard skips a chain the class already has, with
  # the options the call gives. So a def that calls `define_callbacks` (or
  # `define_model_callbacks`, any receiver), or a def of the file that calls
  # such a def by name (any receiver) or through `super`, is unplaceable under
  # reload. The match is by name, so it fails closed for a same-named call.
  def test_a_def_that_defines_a_callback_chain_is_unplaceable_under_reload_only
    src = <<~RUBY
      class Job
        def self.job_callbacks(*names)
          define_callbacks(*names, skip_after_callbacks_if_terminated: true)
        end

        def self.all_callbacks = self.job_callbacks(:perform, :enqueue)

        def self.model_callbacks = define_model_callbacks(:create)

        def self.included_hook(base) = base.define_callbacks(:save)

        def self.constant_receiver = Job.job_callbacks(:x)

        def self.outer
          def self.nested = define_callbacks(:nested)
        end

        class << self
          def eigen_helper = define_callbacks(:eigen)
          def eigen_caller = eigen_helper
        end

        def perform = 1
      end

      class SubJob < Job
        def self.job_callbacks(*names) = super

        def self.unrelated = job_callbacks
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      by_name = subjects.to_h { |s| [s.qualified_name, s] }
      %w[Job.job_callbacks Job.all_callbacks Job.model_callbacks Job.included_hook Job.constant_receiver
         Job.outer Job.nested Job.eigen_helper Job.eigen_caller SubJob.job_callbacks SubJob.unrelated].each do |name|
        assert by_name.fetch(name).calls_define_callbacks, name
        assert by_name.fetch(name).unplaceable?("reload"), name
        refute by_name.fetch(name).unplaceable?("redefine"), name
      end
      refute by_name.fetch("Job#perform").calls_define_callbacks
      refute by_name.fetch("Job#perform").unplaceable?("reload")
    end
  end

  # #543, R21 of the plan (AE16): the reload drops a conditional skip the first
  # load applied, so a def that makes a skip the file runs at load, or that
  # gives a load-time skip its filter or condition, is unplaceable under
  # reload only. A file with no load-time skip call marks none.
  def test_a_def_that_makes_a_load_time_skip_is_unplaceable_under_reload_only
    src = <<~RUBY
      class Note < Base
        def self.quieten = skip_callback(:save, :before, :stamp, if: :quiet?)
        def self.louder = quieten
        def self.allow(**options) = skip_before_action(:check, **options)
        def self.helper_only = 1
        def self.inner = (def self.deep = quieten)
        def self.hush = skip_callback(:save, :before, :stamp, if: hush_condition)
        def self.hush_condition = :quiet?
        def stamp_filter = :stamp
        def quiet_condition = :quiet?
        def quiet? = true

        quieten
        hush
        skip_callback :save, :before, stamp_filter, if: quiet_condition
        skip_callback :save, :after, :stamp, if: -> { quiet? }
      end
    RUBY
    with_source(src) do |path|
      by_name = Mutineer::Project.discover([path]).to_h { |s| [s.qualified_name, s] }
      %w[Note.quieten Note.louder Note.allow Note.inner Note.deep Note.hush Note.hush_condition Note#stamp_filter
         Note#quiet_condition].each do |name|
        assert by_name.fetch(name).makes_load_time_skip, name
        assert by_name.fetch(name).unplaceable?("reload"), name
        refute by_name.fetch(name).unplaceable?("redefine"), name
      end
      %w[Note.helper_only Note#quiet?].each do |name|
        refute by_name.fetch(name).makes_load_time_skip, name
        refute by_name.fetch(name).unplaceable?("reload"), name
      end
    end
    # No load of this file calls a skip def, as for a concern's
    # `allow_unauthenticated_access`; a call inside another def is not a load-time call.
    src = <<~RUBY
      module Authentication
        def self.allow(**options) = skip_before_action(:check, **options)
        def self.setup = allow(only: :index)
        def self.hush = skip_callback(:save, :before, :stamp, if: gate)
        def self.gate = :quiet?
      end
    RUBY
    with_source(src) do |path|
      subjects = Mutineer::Project.discover([path])
      refute(subjects.any?(&:makes_load_time_skip), subjects.map(&:qualified_name).inspect)
      refute(subjects.any? { |subject| subject.unplaceable?("reload") })
    end
    src = "class Controller < Base\n  def self.open_up = skip_before_action(:check)\n  open_up\nend\n"
    with_source(src) do |path|
      assert Mutineer::Project.discover([path]).first.makes_load_time_skip, "an unconditional skip def is marked too"
    end
  end

  # #533: a constant whose value holds only data names the same data on each
  # load, so a superclass that reads it is not stale.
  def test_data_literal_accepts_only_values_that_hold_no_class
    data = ["1", ":a", "\"s\"", "nil", "true", "1.5", "%i[a b]", "[1, [2, :c]]", "{ a: 1, \"b\" => [2] }",
            "%i[a b].freeze", "{ k: 1 }.freeze", "[]"]
    other = ["Foo", "build", "Struct.new(:a)", "x.freeze", "[Foo]", "{ a: Foo }", "\"\#{x}\"", "[1].map(&:to_s)",
             "%i[a].freeze(1)", "{ **opts }"]
    (data.map { |text| [text, true] } + other.map { |text| [text, false] }).each do |text, expected|
      value = Mutineer::Parser.parse_string("X = #{text}\n").value.statements.body.first.value
      assert_equal expected, Mutineer::Project.data_literal?(value), text
    end
  end

  # #533: the names a load of the file can build again: its defs, and the
  # constants it writes with a value that is neither data nor kept by reload.
  def test_rebuilt_names_reads_defs_and_constants_reload_does_not_keep
    program = Mutineer::Parser.parse_string(<<~RUBY).value
      def self.build_base = 1
      class Row
        def total = 1
      end
      DATA_ONLY = %i[a].freeze
      Kept = Struct.new(:v)
      Called = build_base
      A, Multi = 1, 2
      Billing::Path = make
      Or ||= Struct.new(:v)
      Twice = Struct.new(:v)
      Twice = Struct.new(:w)
    RUBY
    defs, constants = Mutineer::Project.rebuilt_names(program)
    assert_equal Set[:build_base, :total], defs
    assert_equal Set[:Called, :A, :Multi, :Path, :Or, :Twice], constants
  end

  # #528, R22: the last names of the constants the file writes more than
  # once, with any kind of write, a path write or a multiple-assignment target.
  def test_repeated_constant_names_counts_every_kind_of_write
    program = Mutineer::Parser.parse_string("A = 1\nA = 2\nB = 1\nB ||= 2\nC = 1\nX::C = 2\nD = 1\nE, D = 1, 2\n" \
                                            "F = 1\nclass F; end\nmodule G; end\nG = 1\nH += 1\n").value
    assert_equal Set[:A, :B, :C, :D], Mutineer::Project.repeated_constant_names(program)
  end

  # #528, P1 and P2 of the self-check, test the rule: a constant the file
  # changes at load in a way that is not safe to run again on a kept class is
  # not kept. A class statement with a safe body, `new` and `[]` are safe.
  RESHAPED = {
    "class P\n  alias_method :raw_x, :x\nend\n" => true,
    "class P\n  undef_method :to_a\nend\n" => true,
    "class P\n  remove_method :to_a\nend\n" => true,
    "class P\n  include Comparable\nend\n" => true,
    "module A\n  class P\n    alias b a\n  end\nend\n" => true,
    "module P\n  extend self\nend\n" => true,
    "class << P\n  alias_method :b, :a\nend\n" => true,
    "P.freeze\n" => true,
    "P.class_eval { def y = 1 }\n" => true,
    "A::P.send(:remove_method, :to_a)\n" => true,
    "P.include(Comparable)\n" => true,
    "class P\n  def y = 1\n  attr_reader :z\nend\n" => false,
    "class << P\n  def s = 1\nend\n" => false,
    "ORIGIN = P.new(0)\n" => false,
    "ORIGIN = P[0]\n" => false,
    "def self.seal = P.freeze\n" => true,
    "Alias = P\nAlias.class_eval { alias_method :raw_x, :x }\n" => true,
    "[P].each { |k| k.class_eval { alias_method :raw_x, :x } }\n" => true,
    "def self.patch(k) = k.alias_method(:raw_x, :x)\npatch(P)\n" => true,
    "def p?(v) = v.is_a?(P)\n" => true,
    "class Q\n  alias_method :b, :a\nend\n" => false,
    "class Row < P\nend\n" => false,
    "class Row < Class.new(P)\nend\n" => false,
    "ORIGIN = P::ZERO\n" => false,
    "A::ORIGIN = A::P.new(0)\n" => false,
    "class P::Q\n  alias_method :b, :a\nend\n" => true,
    "class P::Q\n  def b = 1\nend\n" => false,
    "ORIGIN = P.new(0)\nORIGIN.class.class_eval { alias_method :raw_x, :x }\n" => true,
    "KLASS = Object.const_get(:P)\n" => true
  }.freeze

  def test_unkept_constant_names_holds_a_constant_the_file_may_change
    RESHAPED.each do |text, unkept|
      ["P = Struct.new(:x)\n", "A::P = Struct.new(:x)\n"].each do |write_text|
        program = Mutineer::Parser.parse_string(write_text + text).value
        names = Mutineer::Project.unkept_constant_names(program)
        assert_equal unkept, names.include?(:P), write_text + text
        assert_equal !unkept, Mutineer::Project.kept_constant_write?(program.statements.body.first, names), write_text + text
      end
    end
  end

  # #528, P1 of the pre-PR review: the reload text reads the kept constants
  # from the original text. A mutant that removes the only `Point.members`
  # call inside a def must not make the reload keep a class whose block does
  # not run again: the mutated def would never load, a false survivor.
  def test_the_reload_text_keeps_the_constants_the_original_text_keeps
    source = "Point = Struct.new(:x) do\n  alias_method :raw_x, :x\n  def self.fields\n    Point.members\n  end\nend\n"
    mutated = source.sub("Point.members", "nil")
    assert_includes Mutineer::JobPlan.keep_live_superclasses(mutated), "kept_constant"
    assert_equal mutated, Mutineer::JobPlan.reload_code(mutated, nil, nil, source).first
    with_source(source) do |path|
      subject = Mutineer::Project.discover([path]).find { |s| s.qualified_name == "Point.fields" }
      refute subject.unplaceable?("reload")
    end
  end
end
