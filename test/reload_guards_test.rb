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
