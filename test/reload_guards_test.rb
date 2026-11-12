# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/reload_guards"
require "tmpdir"

# #378, #384: the guards relax two Rails macros only while a mutant loads.
# Stand-ins replace the Rails modules, so the suite stays Rails-free.
class ReloadGuardsTest < Minitest::Test
  # Stands in for ActiveRecord::Enum: like Rails, it records a new enum after
  # the first conflict check, then checks each value's method.
  class EnumHost
    class << self
      def defined_enums = (@defined_enums ||= { "status" => {} })

      def declare(name)
        detect_enum_conflict!(name, name)
        defined_enums[name.to_s] = {}
        detect_enum_conflict!(name, :"#{name}_value?")
      end

      def reset! = (@defined_enums = nil)

      private

      # Every check finds a conflict, so a skipped check shows as no raise.
      def detect_enum_conflict!(name, method) = raise(ArgumentError, "conflict: #{name} #{method}")
    end
    singleton_class.prepend(Mutineer::ReloadGuards::EnumRedeclaration)
  end

  def teardown
    EnumHost.reset!
  end

  # Stands in for a callback in ActiveSupport::Callbacks.
  Callback = Struct.new(:kind, :filter)

  # Stands in for a Rails parent that defines `before save :check`. It has no
  # `check` method, so only its callback chain can explain a skip of it.
  class CallbackParent
    def self.__callbacks = { save: [Callback.new(:before, :check)] }
  end

  # Stands in for a class whose first run already skipped its callbacks: like
  # Rails, a skip raises unless it passes `raise: false`. `concern_check`
  # stands for a callback method an included concern installed.
  class CallbackHost < CallbackParent
    class << self
      attr_reader :options

      def skip_callback(_name, *filters)
        @options = filters.last.is_a?(Hash) ? filters.last : {}
        raise ArgumentError, "callback has not been defined" unless @options[:raise] == false
      end
    end
    singleton_class.prepend(Mutineer::ReloadGuards::CallbackReskipping)

    private

    def concern_check = nil
  end

  def test_an_enum_the_class_has_skips_its_conflict_check_only_during_a_load
    assert_raises(ArgumentError) { EnumHost.declare(:status) }
    Mutineer::ReloadGuards.during_load("unused.rb") { EnumHost.declare(:status) }
    assert_raises(ArgumentError) { EnumHost.declare(:status) }
  end

  # Rails records a new enum after its first check. The value check after that
  # must still run, so the stand-in's conflict on it raises.
  def test_a_new_enum_keeps_its_conflict_check_during_a_load
    error = assert_raises(ArgumentError) do
      Mutineer::ReloadGuards.during_load("unused.rb") { EnumHost.declare(:kind) }
    end
    assert_equal "conflict: kind kind", error.message
  end

  def test_a_new_enum_keeps_its_value_checks_after_rails_records_it
    error = assert_raises(ArgumentError) do
      Mutineer::ReloadGuards.during_load("unused.rb") do
        EnumHost.send(:detect_enum_conflict!, :kind, :kind) rescue nil # rubocop:disable Style/RescueModifier
        EnumHost.defined_enums["kind"] = {}
        EnumHost.send(:detect_enum_conflict!, :kind, :kind_value?)
      end
    end
    assert_equal "conflict: kind kind_value?", error.message
  end

  # A loader that does not manage the file raises Zeitwerk::Error; the next one
  # is asked. With no Rails, nothing is asked.
  def test_load_original_asks_each_autoloader_until_one_manages_the_file
    asked = []
    unmanaged = Object.new.tap { |l| l.define_singleton_method(:load_file) { |path| asked << [:once, path]; raise Zeitwerk::Error } }
    main = Object.new.tap { |l| l.define_singleton_method(:load_file) { |path| asked << [:main, path] } }
    Object.const_set(:Zeitwerk, Module.new.tap { |z| z.const_set(:Error, Class.new(StandardError)) })
    rails = Module.new.tap { |r| r.define_singleton_method(:autoloaders) { [unmanaged, main] } }
    rails.define_singleton_method(:application) { Object.new }
    Object.const_set(:Rails, rails)

    Mutineer::ReloadGuards.load_original("app/models/a.rb")
    path = File.expand_path("app/models/a.rb")
    assert_equal [[:once, path], [:main, path]], asked
  ensure
    Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
    Object.send(:remove_const, :Zeitwerk) if Object.const_defined?(:Zeitwerk, false)
  end

  # A library or gem can load railties and Zeitwerk with no Rails app. Rails
  # then has no application, and `Rails.autoloaders` raises NoMethodError, so
  # nothing is asked and the load goes on.
  def test_load_original_asks_nothing_without_a_rails_application
    Object.const_set(:Zeitwerk, Module.new.tap { |z| z.const_set(:Error, Class.new(StandardError)) })
    rails = Module.new.tap { |r| r.define_singleton_method(:application) { nil } }
    rails.define_singleton_method(:autoloaders) { application.autoloaders }
    Object.const_set(:Rails, rails)

    assert_nil Mutineer::ReloadGuards.load_original("lib/a.rb")
  ensure
    Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
    Object.send(:remove_const, :Zeitwerk) if Object.const_defined?(:Zeitwerk, false)
  end

  # A managed file that does not define the constant Zeitwerk expects raises
  # Zeitwerk::NameError, a NameError. The mutant load goes on, as before #383.
  def test_load_original_goes_on_when_a_loader_raises_name_error
    asked = []
    misnamed = Object.new.tap { |l| l.define_singleton_method(:load_file) { |path| asked << path; raise NameError, "expected A" } }
    Object.const_set(:Zeitwerk, Module.new.tap { |z| z.const_set(:Error, Class.new(StandardError)) })
    rails = Module.new.tap { |r| r.define_singleton_method(:autoloaders) { [misnamed] } }
    rails.define_singleton_method(:application) { Object.new }
    Object.const_set(:Rails, rails)

    Mutineer::ReloadGuards.load_original("lib/core_ext/a.rb")
    assert_equal [File.expand_path("lib/core_ext/a.rb")], asked
  ensure
    Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
    Object.send(:remove_const, :Zeitwerk) if Object.const_defined?(:Zeitwerk, false)
  end

  # Autoload roots are real paths, so a source path through a symlink must
  # reach the loaders as the real path, or none manages it.
  def test_load_original_passes_the_real_path_of_a_symlinked_file
    Dir.mktmpdir do |dir|
      real = File.join(dir, "real.rb")
      File.write(real, "")
      link = File.join(dir, "link.rb")
      File.symlink(real, link)
      asked = []
      main = Object.new.tap { |l| l.define_singleton_method(:load_file) { |path| asked << path } }
      Object.const_set(:Zeitwerk, Module.new.tap { |z| z.const_set(:Error, Class.new(StandardError)) })
      rails = Module.new.tap { |r| r.define_singleton_method(:autoloaders) { [main] } }
      rails.define_singleton_method(:application) { Object.new }
      Object.const_set(:Rails, rails)

      Mutineer::ReloadGuards.load_original(link)
      assert_equal [File.realpath(real)], asked
    end
  ensure
    Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
    Object.send(:remove_const, :Zeitwerk) if Object.const_defined?(:Zeitwerk, false)
  end

  # Runs the block with a stand-in `ActiveSupport` module, then puts back the
  # one an earlier test defined, so later tests in any order still see it.
  def with_active_support(active_support)
    previous = Object.const_get(:ActiveSupport, false) if Object.const_defined?(:ActiveSupport, false)
    Object.send(:remove_const, :ActiveSupport) if previous
    Object.const_set(:ActiveSupport, active_support)
    yield
  ensure
    Object.send(:remove_const, :ActiveSupport) if Object.const_defined?(:ActiveSupport, false)
    Object.const_set(:ActiveSupport, previous) if previous
  end

  # A process that only set ActiveSupport::Callbacks to autoload has not loaded
  # it. Neither the snapshot nor the guards may load it, or the mutant run
  # would see methods the clean run did not have.
  def test_an_autoloaded_callbacks_module_stays_unloaded
    Dir.mktmpdir do |dir|
      path = File.join(dir, "callbacks.rb")
      File.write(path, "raise 'ActiveSupport::Callbacks loaded'")
      active_support = Module.new
      active_support.autoload(:Callbacks, path)
      with_active_support(active_support) do
        assert_equal({}, Mutineer::ReloadGuards::RepeatedCallbacks.snapshot)
        Mutineer::ReloadGuards.install!
        assert_equal path, active_support.autoload?(:Callbacks)
      end
    end
  end

  # A class can define its own class-level `<`, as `extend Comparable` does.
  # The snapshot asks the module instead, so that class does not raise.
  def test_the_snapshot_handles_a_class_that_defines_its_own_comparison
    callbacks = Module.new
    active_support = Module.new.tap { |m| m.const_set(:Callbacks, callbacks) }
    klass = Class.new do
      include callbacks
      extend Comparable
      def self.<=>(_other) = nil
      def self.__callbacks = { save: [] }
    end

    with_active_support(active_support) do
      assert_raises(ArgumentError) { klass < callbacks }
      assert_equal({ save: [] }, Mutineer::ReloadGuards::RepeatedCallbacks.snapshot.fetch(klass))
    end
  end

  def test_skipping_a_parent_callback_again_does_not_raise_only_during_a_load
    assert_raises(ArgumentError) { CallbackHost.skip_callback(:save, :before, :check) }

    Mutineer::ReloadGuards.during_load("unused.rb") { CallbackHost.skip_callback(:save, :before, :check, if: :x) }
    assert_equal({ raise: false, if: :x }, CallbackHost.options)
  end

  # Qodo, cubic: Rails defaults a missing kind to `:before`.
  def test_a_skip_without_a_kind_counts_as_before
    Mutineer::ReloadGuards.during_load("unused.rb") { CallbackHost.skip_callback(:save, :check) }
    assert_equal({ raise: false }, CallbackHost.options)
  end

  # Devin, cubic: a concern's included block installed the callback on the
  # class itself, and a reload does not run that block again.
  def test_skipping_a_callback_named_by_a_method_of_the_class_does_not_raise_during_a_load
    Mutineer::ReloadGuards.during_load("unused.rb") { CallbackHost.skip_callback(:save, :before, :concern_check) }
    assert_equal({ raise: false }, CallbackHost.options)
  end

  # A skip that names no method of the class and no parent callback keeps
  # Rails' check during a load, so a typo still raises.
  def test_a_skip_nothing_explains_still_raises_during_a_load
    Mutineer::ReloadGuards.during_load("unused.rb") do
      assert_raises(ArgumentError) { CallbackHost.skip_callback(:save, :before, :typo) }
      assert_raises(ArgumentError) { CallbackHost.skip_callback(:save, :after, :check) }
      assert_raises(ArgumentError) { CallbackHost.skip_callback(:create, :before, :check) }
    end
  end

  def test_an_explicit_raise_option_wins_during_a_load
    assert_raises(ArgumentError) do
      Mutineer::ReloadGuards.during_load("unused.rb") { CallbackHost.skip_callback(:save, :before, :check, raise: true) }
    end
    assert_equal({ raise: true }, CallbackHost.options)
  end

  def test_the_guard_turns_off_when_the_load_raises
    assert_raises(RuntimeError) { Mutineer::ReloadGuards.during_load("unused.rb") { raise "boom" } }
    refute Mutineer::ReloadGuards.loading?
  end

  # Stands in for an ActiveSupport callback chain.
  class Chain
    include Enumerable

    def initialize(*callbacks) = (@callbacks = callbacks)
    def each(&) = @callbacks.each(&)
    def clear = @callbacks.clear
    def append(*callbacks) = @callbacks.concat(callbacks)
  end

  # Stands in for an ActiveModel validator: one class, its attributes and
  # options, kept in instance variables as Rails keeps them.
  class Validator
    attr_reader :attributes, :options

    def initialize(attributes, options)
      @attributes = attributes
      @options = options
    end
  end

  # A class with callback chains and validators, as ActiveSupport keeps them.
  def callback_class(parent = Object)
    Class.new(parent) do
      singleton_class.attr_accessor :__callbacks, :_validators
      self._validators = {}
    end
  end

  def assert_same_list(expected, actual)
    assert_equal expected.map(&:object_id), actual.to_a.map(&:object_id)
  end

  # #390: a second run of the class body appended a new copy of the validator
  # (with a mutated option), the block, and the method callback; Rails already
  # dropped the old method callback. One copy of each stays, in its old place.
  def test_a_reload_keeps_one_copy_of_each_callback_and_validator_in_the_original_order
    old_validator = Validator.new([:weight], { greater_than: 0 })
    new_validator = Validator.new([:weight], { greater_than: 5 })
    old = [Callback.new(:before, old_validator), Callback.new(:before, proc {}), Callback.new(:before, :check)]
    new = [Callback.new(:before, new_validator), Callback.new(:before, proc {}), Callback.new(:before, :check)]
    klass = callback_class
    klass.__callbacks = { validate: Chain.new(old[0], old[1], new[0], new[1], new[2]) }
    klass._validators = { weight: [old_validator, new_validator] }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { validate: old } }, [__FILE__])

    assert_same_list new, klass.__callbacks[:validate]
    assert_same_list [new_validator], klass._validators[:weight]
  end

  # Only the parent's body ran again. Its new block reached the subclass too;
  # the subclass's own callback, which the load did not repeat, stays in place.
  def test_a_class_the_load_did_not_run_again_keeps_its_own_callbacks
    old_block = Callback.new(:before, proc {})
    new_block = Callback.new(:before, proc {})
    own = Callback.new(:before, proc {})
    parent = callback_class
    child = callback_class(parent)
    parent.__callbacks = { save: Chain.new(old_block, new_block) }
    child.__callbacks = { save: Chain.new(old_block, own, new_block) }
    before = { parent => { save: [old_block] }, child => { save: [old_block, own] } }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    assert_same_list [new_block], parent.__callbacks[:save]
    assert_same_list [new_block, own], child.__callbacks[:save]
  end

  # #414: only the parent's body ran again. Rails appended its new `:check`
  # to every loaded subclass, also to one that skipped it and to one that kept
  # only a conditional copy, which Rails then dropped as a duplicate. Each
  # subclass must end as it was: no `:check`, or its own conditional copy.
  def test_a_parent_reload_keeps_each_subclass_skip
    old_check = Callback.new(:before, :check)
    new_check = Callback.new(:before, :check)
    conditional = Callback.new(:before, :check).tap { |c| c.instance_variable_set(:@unless, [:express?]) }
    own = Callback.new(:before, proc {})
    parent = callback_class
    skipped = callback_class(parent)
    narrowed = callback_class(parent)
    parent.__callbacks = { save: Chain.new(new_check) }
    skipped.__callbacks = { save: Chain.new(own, new_check) }
    narrowed.__callbacks = { save: Chain.new(new_check) }
    before = { parent => { save: [old_check] }, skipped => { save: [own] }, narrowed => { save: [conditional] } }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    assert_same_list [new_check], parent.__callbacks[:save]
    assert_same_list [own], skipped.__callbacks[:save]
    assert_same_list [conditional], narrowed.__callbacks[:save]
  end

  # Stands in for ActiveSupport::Callbacks::Callback. `initialize` freezes the
  # condition lists and records them as `@compiled`, as Rails 8 does when it
  # builds the callback. A copy whose lists are changed later still runs the
  # compiled ones. `merge_conditional_options` matches Rails 7.1 and 8.0:
  # a skip's `unless:` is appended to `@if`, and its `if:` to `@unless`.
  class ConditionalCallback
    attr_reader :kind, :filter, :name, :chain_config

    def initialize(name, filter, kind, options, chain_config)
      @name = name
      @filter = filter
      @kind = kind
      @chain_config = chain_config
      @if = Array(options[:if]).freeze
      @unless = Array(options[:unless]).freeze
      @compiled = [@if, @unless]
    end

    def self.build(chain, filter, kind, options)
      new(chain.name, filter, kind, options, chain.config)
    end

    def merge_conditional_options(chain, if_option:, unless_option:)
      options = { if: @if.dup, unless: @unless.dup }
      options[:if].concat(Array(unless_option))
      options[:unless].concat(Array(if_option))
      self.class.build(chain, @filter, @kind, options)
    end
  end

  def save_callback(filter, config, if_list:, unless_list:)
    chain = Struct.new(:name, :config).new(:save, config)
    ConditionalCallback.build(chain, filter, :before, { if: if_list, unless: unless_list })
  end

  # #440: the parent callback has conditions, and the subclass skip leaves a
  # merged copy. Rails then appends the reloaded parent callback and drops
  # the copy. The copy holds the parent's old condition objects, so putting
  # it back would hide the mutant. The chain must run the reloaded objects,
  # with the subclass's own conditions after them. `@compiled` is what runs:
  # a dup of the old copy, with its lists patched, would still compile the
  # old objects. Reload and the daemon share this path. Redefine does not
  # re-run the class body.
  def test_a_restored_skip_carries_the_reloaded_parent_conditions
    old_heavy = :heavy?
    new_light = :light?
    old_limit = -> { false }
    new_limit = -> { true }
    old_draft = -> { false }
    new_draft = -> { true }
    # A subclass `skip unless: :bulk?` is stored on `@if`. Two `skip if:`
    # options are stored on `@unless`, in that order.
    bulk = :bulk?
    express = :express?
    gift = :gift?
    old_config = { scope: [:kind] }
    new_config = { scope: [:kind] }
    old_parent = save_callback(:check, old_config, if_list: [old_heavy, old_limit], unless_list: [old_draft])
    new_parent = save_callback(:check, new_config, if_list: [new_light, new_limit], unless_list: [new_draft])
    merged = save_callback(:check, old_config, if_list: [old_heavy, old_limit, bulk], unless_list: [old_draft, express, gift])
    own = Callback.new(:before, proc {})
    own_rule = :own_rule
    independent = save_callback(:check, old_config, if_list: [own_rule], unless_list: [])
    parent = callback_class
    narrowed = callback_class(parent)
    skipped = callback_class(parent)
    override = callback_class(parent)
    parent.__callbacks = { save: Chain.new(new_parent) }
    narrowed.__callbacks = { save: Chain.new(new_parent) }
    skipped.__callbacks = { save: Chain.new(own, new_parent) }
    override.__callbacks = { save: Chain.new(new_parent) }
    before = {
      parent => { save: [old_parent] },
      narrowed => { save: [merged] },
      skipped => { save: [own] },
      override => { save: [independent] }
    }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    restored = narrowed.__callbacks[:save].to_a
    assert_equal 1, restored.size
    callback = restored.fetch(0)
    compiled_if, compiled_unless = callback.instance_variable_get(:@compiled)
    assert_same new_light, compiled_if[0]
    assert_same new_limit, compiled_if[1]
    assert_same bulk, compiled_if[2]
    assert_same new_draft, compiled_unless[0]
    assert_same express, compiled_unless[1]
    assert_same gift, compiled_unless[2]
    refute_includes compiled_if, old_heavy
    refute_includes compiled_if, old_limit
    refute_includes compiled_unless, old_draft
    refute_same merged, callback
    refute_same new_parent, callback
    assert_equal :before, callback.kind
    assert_equal :check, callback.filter
    assert_equal :save, callback.name
    assert_same new_config, callback.chain_config
    assert_equal [new_light, new_limit], new_parent.instance_variable_get(:@if)
    assert_equal [new_draft], new_parent.instance_variable_get(:@unless)
    assert_same_list [new_parent], parent.__callbacks[:save]
    assert_same_list [own], skipped.__callbacks[:save]
    assert_same_list [independent], override.__callbacks[:save]
    assert_equal [own_rule], override.__callbacks[:save].to_a.fetch(0).instance_variable_get(:@if)
  end

  # The reloaded callback still has the parent's condition objects, so the
  # merged copy is already what a fresh boot would build. It stays that object.
  def test_a_restored_skip_keeps_the_copy_when_parent_conditions_are_unchanged
    heavy = :heavy?
    draft = -> { false }
    express = :express?
    config = { scope: [:kind] }
    old_parent = save_callback(:check, config, if_list: [heavy], unless_list: [draft])
    new_parent = save_callback(:check, config, if_list: [heavy], unless_list: [draft])
    merged = save_callback(:check, config, if_list: [heavy, express], unless_list: [draft])
    parent = callback_class
    narrowed = callback_class(parent)
    parent.__callbacks = { save: Chain.new(new_parent) }
    narrowed.__callbacks = { save: Chain.new(new_parent) }
    before = { parent => { save: [old_parent] }, narrowed => { save: [merged] } }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    assert_same_list [merged], narrowed.__callbacks[:save]
    assert_same_list [new_parent], parent.__callbacks[:save]
  end

  # A parent with no conditions has no objects to show the copy was merged
  # from one. The subclass copy stays, including when the reload adds a
  # condition: a subclass callback of the same name has this same shape
  # (#414) and must not gain the parent's new condition.
  def test_a_parent_with_no_conditions_keeps_the_subclass_copy
    added = -> { true }
    express = :express?
    old_config = { scope: [:kind] }
    new_config = { scope: [:kind] }
    old_parent = save_callback(:check, old_config, if_list: [], unless_list: [])
    new_parent = save_callback(:check, new_config, if_list: [added], unless_list: [])
    merged = save_callback(:check, old_config, if_list: [], unless_list: [express])
    parent = callback_class
    narrowed = callback_class(parent)
    parent.__callbacks = { save: Chain.new(new_parent) }
    narrowed.__callbacks = { save: Chain.new(new_parent) }
    before = { parent => { save: [old_parent] }, narrowed => { save: [merged] } }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    assert_same_list [merged], narrowed.__callbacks[:save]
    assert_same_list [new_parent], parent.__callbacks[:save]
    refute_includes merged.instance_variable_get(:@compiled).flatten, added
  end

  # `:active?` is one object everywhere it is written. An independent
  # `before_save :check, if: :active?` shares it with the parent and is not a
  # skip merge. A reload that changes the parent to `if: :ready?` must leave
  # both the exact copy and a longer list that starts with `:active?`. The
  # `unless:` sibling is the same rule.
  def test_an_independent_callback_keeps_a_shared_condition_symbol
    old_config = { scope: [:kind] }
    new_config = { scope: [:kind] }
    old_parent = save_callback(:check, old_config, if_list: [:active?], unless_list: [])
    new_parent = save_callback(:check, new_config, if_list: [:ready?], unless_list: [])
    exact = save_callback(:check, old_config, if_list: [:active?], unless_list: [])
    longer = save_callback(:check, old_config, if_list: [:active?, :mine?], unless_list: [])
    parent = callback_class
    exact_child = callback_class(parent)
    longer_child = callback_class(parent)
    parent.__callbacks = { save: Chain.new(new_parent) }
    exact_child.__callbacks = { save: Chain.new(new_parent) }
    longer_child.__callbacks = { save: Chain.new(new_parent) }
    before = {
      parent => { save: [old_parent] },
      exact_child => { save: [exact] },
      longer_child => { save: [longer] }
    }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    assert_same_list [exact], exact_child.__callbacks[:save]
    assert_same_list [longer], longer_child.__callbacks[:save]
    refute_includes exact.instance_variable_get(:@compiled).flatten, :ready?
    refute_includes longer.instance_variable_get(:@compiled).flatten, :ready?
    assert_same :active?, longer.instance_variable_get(:@if)[0]
    assert_same :mine?, longer.instance_variable_get(:@if)[1]

    old_unless = save_callback(:weigh, old_config, if_list: [], unless_list: [:draft?])
    new_unless = save_callback(:weigh, new_config, if_list: [], unless_list: [:sent?])
    unless_copy = save_callback(:weigh, old_config, if_list: [], unless_list: [:draft?])
    unless_parent = callback_class
    unless_child = callback_class(unless_parent)
    unless_parent.__callbacks = { save: Chain.new(new_unless) }
    unless_child.__callbacks = { save: Chain.new(new_unless) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(
      { unless_parent => { save: [old_unless] }, unless_child => { save: [unless_copy] } }, [__FILE__]
    )

    assert_same_list [unless_copy], unless_child.__callbacks[:save]
    refute_includes unless_copy.instance_variable_get(:@compiled).flatten, :sent?
  end

  # A symbol-only skip has the same shape as an independent callback, so the
  # old copy stays. A Proc in the parent list is what shows the copy was
  # merged; that case is
  # `test_a_restored_skip_carries_the_reloaded_parent_conditions`.
  def test_a_symbol_only_skip_keeps_the_old_parent_symbol
    old_config = { scope: [:kind] }
    new_config = { scope: [:kind] }
    old_parent = save_callback(:check, old_config, if_list: [:active?], unless_list: [])
    new_parent = save_callback(:check, new_config, if_list: [:ready?], unless_list: [])
    merged = save_callback(:check, old_config, if_list: [:active?], unless_list: [:express?])
    parent = callback_class
    narrowed = callback_class(parent)
    parent.__callbacks = { save: Chain.new(new_parent) }
    narrowed.__callbacks = { save: Chain.new(new_parent) }
    before = { parent => { save: [old_parent] }, narrowed => { save: [merged] } }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    assert_same_list [merged], narrowed.__callbacks[:save]
    refute_includes merged.instance_variable_get(:@compiled).flatten, :ready?
    assert_same :express?, merged.instance_variable_get(:@unless)[0]
  end

  # Two ancestors reload a callback of the same name. The chain lists the
  # unrelated one first. The copy was merged from the other, so the rebuild
  # uses that one's new Proc, not the old copy and not the first stray.
  def test_a_restored_skip_uses_the_ancestor_it_was_merged_from
    grand_old = -> { false }
    grand_new = -> { true }
    parent_old = -> { false }
    parent_new = -> { true }
    bulk = :bulk?
    old_config = { scope: [:kind] }
    new_config = { scope: [:kind] }
    grand_before = save_callback(:check, old_config, if_list: [grand_old], unless_list: [])
    grand_after = save_callback(:check, new_config, if_list: [grand_new], unless_list: [])
    parent_before = save_callback(:check, old_config, if_list: [parent_old], unless_list: [])
    parent_after = save_callback(:check, new_config, if_list: [parent_new], unless_list: [])
    merged = save_callback(:check, old_config, if_list: [parent_old, bulk], unless_list: [])
    grand = callback_class
    parent = callback_class(grand)
    child = callback_class(parent)
    grand.__callbacks = { save: Chain.new(grand_after) }
    parent.__callbacks = { save: Chain.new(grand_after, parent_after) }
    child.__callbacks = { save: Chain.new(grand_after, parent_after) }
    before = {
      grand => { save: [grand_before] },
      parent => { save: [grand_before, parent_before] },
      child => { save: [merged] }
    }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    restored = child.__callbacks[:save].to_a
    assert_equal 1, restored.size
    compiled_if, = restored.fetch(0).instance_variable_get(:@compiled)
    assert_same parent_new, compiled_if[0]
    assert_same bulk, compiled_if[1]
    refute_includes compiled_if, parent_old
    refute_includes compiled_if, grand_new
    refute_same merged, restored.fetch(0)
  end

  # The new `:save` callback is the same object as a new `:validate` callback,
  # and the same object as a new callback on a class that is not a subclass.
  # Neither chain loses it. A parent reload still drops it from a subclass
  # that skipped it.
  def test_a_replacement_on_one_chain_stays_on_every_other_chain
    save_old = Callback.new(:before, :check)
    shared = Callback.new(:before, :check)
    validate_old = Callback.new(:before, :weigh)
    other_old = Callback.new(:before, :weigh)
    klass = callback_class
    other = callback_class
    klass.__callbacks = { save: Chain.new(save_old, shared), validate: Chain.new(validate_old, shared) }
    other.__callbacks = { save: Chain.new(other_old, shared) }
    before = { klass => { save: [save_old], validate: [validate_old] }, other => { save: [other_old] } }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    assert_same_list [shared], klass.__callbacks[:save]
    assert_same_list [validate_old, shared], klass.__callbacks[:validate]
    assert_same_list [other_old, shared], other.__callbacks[:save]
  end

  # A block in the class body.
  def body_block = proc {}

  # A block an included concern's `included` block made.
  def concern_block = proc {}

  # Stands in for a lambda a library builds on one line, such as Rails's
  # `has_many dependent:` lambda: each captures its association name.
  def library_lambda(name) = -> { name }

  # Stands in for Rails's `belongs_to touch:` lambda, which captures itself.
  def self_lambda(name)
    callback = nil
    callback = -> { [name, callback] }
  end

  # One reloaded file defines a parent and its subclass. The subclass's old
  # chain holds the parent's block too, so its own new block must pair with
  # its own old block, and each class's validators get the new validator.
  def test_a_parent_and_subclass_in_one_file_keep_one_copy_each
    old_validator = Validator.new([:weight], { greater_than: 0 })
    new_validator = Validator.new([:weight], { greater_than: 5 })
    parent_old = Callback.new(:before, old_validator)
    parent_new = Callback.new(:before, new_validator)
    child_old = Callback.new(:before, body_block)
    child_new = Callback.new(:before, body_block)
    parent = callback_class
    child = callback_class(parent)
    parent.__callbacks = { validate: Chain.new(parent_old, parent_new) }
    child.__callbacks = { validate: Chain.new(parent_old, child_old, parent_new, child_new) }
    parent._validators = { weight: [old_validator, new_validator] }
    child._validators = { weight: [old_validator] }
    before = { parent => { validate: [parent_old] }, child => { validate: [parent_old, child_old] } }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])

    assert_same_list [parent_new], parent.__callbacks[:validate]
    assert_same_list [parent_new, child_new], child.__callbacks[:validate]
    assert_same_list [new_validator], parent._validators[:weight]
    assert_same_list [new_validator], child._validators[:weight]
  end

  # An included concern from another file added a library lambda and a
  # validator that look like the class body's own. The reload does not run the
  # concern's block again, so only the class body's entries repeat, and only
  # they are swapped: the concern's entries stay.
  def test_a_concern_lambda_and_validator_like_the_class_body_ones_stay
    concern_entries = [Callback.new(:before, library_lambda(:comments)),
                       Callback.new(:before, Validator.new([:title], { maximum: 5 }))]
    old_body = [Callback.new(:before, library_lambda(:tags)),
                Callback.new(:before, Validator.new([:title], { minimum: 2 }))]
    new_body = [Callback.new(:before, library_lambda(:tags)),
                Callback.new(:before, Validator.new([:title], { minimum: 2 }))]
    klass = callback_class
    klass.__callbacks = { save: Chain.new(*concern_entries, *old_body, *new_body) }

    # The reloaded file is another one, so these lambdas count as library code.
    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: concern_entries + old_body } }, ["model.rb"])

    assert_same_list concern_entries + new_body, klass.__callbacks[:save]
  end

  # The reloaded file also defines the concern. Its `included` block made a
  # block that the reload does not make again, so the class body's new block
  # must pair with the class body's old block, not with the concern's.
  def test_a_concern_block_from_the_reloaded_file_stays
    concern_entry = Callback.new(:before, concern_block)
    old_body = Callback.new(:before, body_block)
    new_body = Callback.new(:before, body_block)
    klass = callback_class
    klass.__callbacks = { save: Chain.new(concern_entry, old_body, new_body) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_body] } }, [__FILE__])

    assert_same_list [concern_entry, new_body], klass.__callbacks[:save]
  end

  # The class's validator has an `if:` block, which is new on each run, so
  # only an equivalent block makes it the same validator. A self-capturing
  # library lambda is matched by what it captured. The concern's look-alikes stay.
  def test_entries_holding_blocks_match_by_where_the_block_is_and_what_it_captured
    concern_entries = [Callback.new(:before, Validator.new([:title], { maximum: 5 })),
                       Callback.new(:after, self_lambda(:parent_a))]
    old_body = [Callback.new(:before, Validator.new([:title], { minimum: 2, if: body_block })),
                Callback.new(:after, self_lambda(:parent_b))]
    new_body = [Callback.new(:before, Validator.new([:title], { minimum: 2, if: body_block })),
                Callback.new(:after, self_lambda(:parent_b))]
    klass = callback_class
    klass.__callbacks = { save: Chain.new(*concern_entries, *old_body, *new_body) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: concern_entries + old_body } }, [__FILE__])

    assert_same_list concern_entries + new_body, klass.__callbacks[:save]
  end

  # A new entry with no equivalent old one pairs by key only when that pairing
  # is certain. Here a concern and the class body each had a validator of that
  # kind, so a guess could drop the concern's: both old ones stay.
  def test_an_unmatched_entry_with_two_candidates_keeps_every_copy
    concern_entry = Callback.new(:before, Validator.new([:title], { maximum: 5 }))
    old_body = Callback.new(:before, Validator.new([:title], { minimum: 2 }))
    new_body = Callback.new(:before, Validator.new([:title], { minimum: 3 }))
    klass = callback_class
    klass.__callbacks = { save: Chain.new(concern_entry, old_body, new_body) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_body] } }, [__FILE__])

    assert_same_list [concern_entry, old_body, new_body], klass.__callbacks[:save]
  end

  # Stands in for ActiveSupport::OptionMerger, which `with_options` yields: it
  # forwards every call, so asking it `equal?` or `==` raises.
  class Proxy < BasicObject
    def method_missing(*) = ::Kernel.raise(::ArgumentError, "forwarded")
    def respond_to_missing?(*) = true
  end

  # A block made inside `with_options do |o|` captures the proxy.
  def proxy_block(proxy) = proc { proxy }

  # A value that cannot be compared matches nothing, so the reload keeps both
  # copies instead of failing every mutant of the file.
  def test_a_block_that_captured_a_proxy_keeps_both_copies_without_raising
    old_entry = Callback.new(:before, proxy_block(Proxy.new))
    new_entry = Callback.new(:before, proxy_block(Proxy.new))
    other = Callback.new(:before, proxy_block(Proxy.new))
    klass = callback_class
    klass.__callbacks = { save: Chain.new(other, old_entry, new_entry) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [other, old_entry] } }, [__FILE__])

    assert_same_list [other, old_entry, new_entry], klass.__callbacks[:save]
  end

  # `&:name` blocks have no source and capture nothing, and callback classes
  # can share class-level state. Each matches only itself, so the concern's
  # entry stays. Rails caches `&:name` per symbol, so a real repeat still
  # matches.
  def test_symbol_blocks_and_callback_classes_match_only_themselves
    concern_entries = [Callback.new(:before, :concern_hook.to_proc), Callback.new(:after, Class.new)]
    old_body = [Callback.new(:before, :own_hook.to_proc), Callback.new(:after, Class.new)]
    new_body = [Callback.new(:before, :own_hook.to_proc), Callback.new(:after, old_body[1].filter)]
    klass = callback_class
    klass.__callbacks = { save: Chain.new(*concern_entries, *old_body, *new_body) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: concern_entries + old_body } }, [__FILE__])

    assert_same_list concern_entries + new_body, klass.__callbacks[:save]
  end

  # Stands in for an ActiveSupport callback with `if:` conditions, which
  # ActiveSupport keeps in `@if`.
  class GuardedCallback
    attr_reader :kind, :filter

    def initialize(kind, filter, condition)
      @kind = kind
      @filter = filter
      @if = [condition]
    end
  end

  # A concern and the class body add one callback class under different
  # conditions. Only the class body's repeats, so the concern's stays.
  def test_one_callback_class_under_different_conditions_keeps_the_concern_entry
    stamp = Class.new
    concern_entry = GuardedCallback.new(:before, stamp, :draft?)
    old_body = GuardedCallback.new(:before, stamp, :published?)
    new_body = GuardedCallback.new(:before, stamp, :published?)
    klass = callback_class
    klass.__callbacks = { save: Chain.new(concern_entry, old_body, new_body) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_body] } }, [__FILE__])

    assert_same_list [concern_entry, new_body], klass.__callbacks[:save]
  end

  # The class body adds one callback only on its first run (`@done ||= ...`).
  # Three old look-alikes and two new ones cannot pair for certain, so every
  # copy stays, as before #390. As many old ones as new ones pair in order.
  def test_look_alike_blocks_pair_only_when_the_counts_match
    old = Array.new(3) { Callback.new(:before, body_block) }
    new = Array.new(2) { Callback.new(:before, body_block) }
    klass = callback_class
    klass.__callbacks = { save: Chain.new(*old, *new) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: old } }, [__FILE__])

    assert_same_list old + new, klass.__callbacks[:save]

    old = Array.new(2) { Callback.new(:before, body_block) }
    klass.__callbacks = { save: Chain.new(*old, *new) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: old } }, [__FILE__])

    assert_same_list new, klass.__callbacks[:save]
  end

  # A callback object whose `call` method is the callback.
  class Stamp
    def initialize(name) = (@name = name)
    def call = @name
  end

  # `before_save(&Stamp.new(:x).method(:call))`: each block comes from one
  # method, so only the receiver tells the concern's and the class body's apart.
  def test_method_blocks_of_different_receivers_are_different_entries
    concern_entry = Callback.new(:before, Stamp.new(:concern).method(:call).to_proc)
    old_body = Callback.new(:before, Stamp.new(:body).method(:call).to_proc)
    new_body = Callback.new(:before, Stamp.new(:body).method(:call).to_proc)
    klass = callback_class
    klass.__callbacks = { save: Chain.new(concern_entry, old_body, new_body) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_body] } }, ["model.rb"])

    assert_same_list [concern_entry, new_body], klass.__callbacks[:save]
  end
end
