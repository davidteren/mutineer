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

  def assert_same_list(expected, actual, message = nil)
    assert_equal expected.map(&:object_id), actual.to_a.map(&:object_id), message
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
  # is certain. Here a concern and the class body each validate :title with
  # `minimum:`, and the mutant changed the body's number, so a guess could
  # drop the concern's: both old ones stay. Different option names are not
  # this case (#413).
  def test_an_unmatched_entry_with_two_candidates_keeps_every_copy
    concern_entry = Callback.new(:before, Validator.new([:title], { minimum: 1 }))
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
  # can share class-level state. A different symbol, and a different class,
  # are not the repeat, so the concern's entries stay. Ruby caches 67
  # `&:name` procs; filling that cache makes the repeat a new object, and it
  # still pairs by the symbol. The same class object still pairs by identity.
  def test_symbol_blocks_and_callback_classes_match_only_themselves
    concern_entries = [Callback.new(:before, :concern_hook.to_proc), Callback.new(:after, Class.new)]
    old_hook = :own_hook.to_proc
    old_body = [Callback.new(:before, old_hook), Callback.new(:after, Class.new)]
    evict_symbol_proc_cache
    new_hook = :own_hook.to_proc
    refute_same old_hook, new_hook
    new_body = [Callback.new(:before, new_hook), Callback.new(:after, old_body[1].filter)]
    klass = callback_class
    klass.__callbacks = { save: Chain.new(*concern_entries, *old_body, *new_body) }

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: concern_entries + old_body } }, [__FILE__])

    assert_same_list concern_entries + new_body, klass.__callbacks[:save]
  end

  # Ruby keeps 67 `Symbol#to_proc` results. One more name drops an older one.
  def evict_symbol_proc_cache
    80.times { |i| :"mutineer_cache_evict_#{i}".to_proc }
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

  # #413: the key used to treat a different symbol, a different block, a
  # different option name or a different condition as the same callback.
  # The concern's entry then blocked the pair, and both copies of the class
  # body's callback stayed. Each row is one real shape. The concern entry
  # must stay, and the new body must take the old body's place.
  def test_a_narrower_key_pairs_the_repeat_and_keeps_the_different_entry
    paired = 0
    pair_rows.each do |row|
      concern, old_entry, new_entry = row.fetch(:entries)
      assert_repeat_replaced(row.fetch(:label), concern, old_entry, new_entry, validators: row[:validators])
      paired += 1
    end
    assert_operator paired, :>, 70, "the corpus must cover many real callback shapes"
  end

  # The same symbol, the same block code, the same option names or the same
  # stateless object under the same condition is still ambiguous: the
  # concern's copy could be the one the new entry repeats. Every copy stays.
  # A fresh anonymous class is a new object with no code of its own, so it
  # matches only itself too.
  def test_an_identical_look_alike_still_keeps_every_copy
    kept = 0
    keep_rows.each do |row|
      concern, old_entry, new_entry = row.fetch(:entries)
      assert_every_copy_stays(row.fetch(:label), concern, old_entry, new_entry)
      kept += 1
    end
    assert_operator kept, :>, 10, "the identical cases must cover each shape the key cannot split"
  end

  # `__FILE__` is the mutant path on the second load. The block is still the
  # same callback, and a different block in the same class is not.
  def test_a_block_that_reads_its_file_pairs_across_the_mutant_path
    verbose = $VERBOSE
    Dir.mktmpdir do |dir|
      source = File.join(dir, "parcel.rb")
      mutant = File.join(dir, "parcel.rb.mut")
      File.write(source, FILE_PATH_CORPUS)
      File.write(mutant, FILE_PATH_CORPUS)
      load source
      concern = FilePathCorpus::OTHER
      old_block = FilePathCorpus::PROC
      $VERBOSE = nil
      load mutant
      new_block = FilePathCorpus::PROC
      refute_same old_block, new_block
      refute_same old_block.binding.local_variable_get(:token), new_block.binding.local_variable_get(:token)

      concern_entry = Callback.new(:before, concern)
      old_entry = Callback.new(:before, old_block)
      new_entry = Callback.new(:before, new_block)
      klass = callback_class
      klass.__callbacks = { save: Chain.new(concern_entry, old_entry, new_entry) }

      Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_entry] } }, [source, mutant])

      assert_same_list [concern_entry, new_entry], klass.__callbacks[:save]

      shifted = File.join(dir, "parcel_shifted.rb")
      File.write(shifted, FILE_PATH_CORPUS_SHIFTED)
      $VERBOSE = nil
      load shifted
      shifted_block = FilePathCorpus::PROC
      shifted_other = FilePathCorpus::OTHER
      concern_entry = Callback.new(:before, shifted_other)
      old_entry = Callback.new(:before, old_block)
      new_entry = Callback.new(:before, shifted_block)
      klass = callback_class
      klass.__callbacks = { save: Chain.new(concern_entry, old_entry, new_entry) }

      Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_entry] } }, [source, shifted])

      assert_same_list [concern_entry, new_entry], klass.__callbacks[:save], "a mutant line above the block"
    end
  ensure
    $VERBOSE = verbose if defined?(verbose)
    Object.send(:remove_const, :FilePathCorpus) if Object.const_defined?(:FilePathCorpus, false)
  end

  # A `rescue` or `ensure` stores a nested sequence whose path and lines
  # differ on the mutant file. The repeat still pairs, and a different block
  # in the same class stays.
  def test_a_rescued_or_ensured_block_pairs_across_the_mutant_path
    verbose = $VERBOSE
    Dir.mktmpdir do |dir|
      source = File.join(dir, "parcel.rb")
      shifted = File.join(dir, "parcel_shifted.rb")
      File.write(source, RESCUE_CORPUS)
      File.write(shifted, RESCUE_CORPUS_SHIFTED)
      $VERBOSE = nil
      load source
      old_rescue = RescueCorpus::PROC
      old_ensured = RescueCorpus::ENSURED
      load shifted
      new_rescue = RescueCorpus::PROC
      new_ensured = RescueCorpus::ENSURED
      other = RescueCorpus::OTHER
      refute_same old_rescue, new_rescue
      refute_same old_rescue.binding.local_variable_get(:token), new_rescue.binding.local_variable_get(:token)

      { rescue: [old_rescue, new_rescue], ensure: [old_ensured, new_ensured] }.each do |label, (old_block, new_block)|
        concern_entry = Callback.new(:before, other)
        old_entry = Callback.new(:before, old_block)
        new_entry = Callback.new(:before, new_block)
        klass = callback_class
        klass.__callbacks = { save: Chain.new(concern_entry, old_entry, new_entry) }

        Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_entry] } }, [source, shifted])

        assert_same_list [concern_entry, new_entry], klass.__callbacks[:save], label.to_s
      end
    end
  ensure
    $VERBOSE = verbose if defined?(verbose)
    Object.send(:remove_const, :RescueCorpus) if Object.const_defined?(:RescueCorpus, false)
  end

  # A mutant changed the callback body, so the compiled code no longer
  # matches. The new body still replaces the old one when nothing else sits
  # at that place. A concern block with the same label is that something
  # else: every copy stays.
  def test_a_mutated_block_pairs_only_when_its_place_is_unique
    verbose = $VERBOSE
    Dir.mktmpdir do |dir|
      source = File.join(dir, "hook.rb")
      mutant = File.join(dir, "hook_mut.rb")
      File.write(source, MUTATED_CORPUS)
      File.write(mutant, MUTATED_CORPUS_CHANGED)
      $VERBOSE = nil
      load source
      old_block = MutatedCorpus.blocks[0]
      other = MutatedCorpus.other
      same_label = MutatedCorpus.blocks[1]
      load mutant
      new_block = MutatedCorpus.blocks[0]
      refute_same old_block, new_block

      alone = Callback.new(:before, old_block)
      changed = Callback.new(:before, new_block)
      klass = callback_class
      klass.__callbacks = { save: Chain.new(alone, changed) }
      Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [alone] } }, [source, mutant])
      assert_same_list [changed], klass.__callbacks[:save], "unique place"

      concern_entry = Callback.new(:before, other)
      old_entry = Callback.new(:before, old_block)
      new_entry = Callback.new(:before, new_block)
      klass = callback_class
      klass.__callbacks = { save: Chain.new(concern_entry, old_entry, new_entry) }
      Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_entry] } }, [source, mutant])
      assert_same_list [concern_entry, new_entry], klass.__callbacks[:save], "different label"

      concern_entry = Callback.new(:before, same_label)
      klass = callback_class
      klass.__callbacks = { save: Chain.new(concern_entry, old_entry, new_entry) }
      Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_entry] } }, [source, mutant])
      assert_same_list [concern_entry, old_entry, new_entry], klass.__callbacks[:save], "same label"
    end
  ensure
    $VERBOSE = verbose if defined?(verbose)
    Object.send(:remove_const, :MutatedCorpus) if Object.const_defined?(:MutatedCorpus, false)
  end

  # The callback body builds an array whose first string is the instruction
  # sequence magic. That array is data, not a nested sequence, and the
  # repeat still pairs across a file whose lines moved.
  def test_a_block_that_builds_an_instruction_shaped_array_pairs
    verbose = $VERBOSE
    Dir.mktmpdir do |dir|
      source = File.join(dir, "magic.rb")
      shifted = File.join(dir, "magic_shifted.rb")
      File.write(source, MAGIC_ARRAY_CORPUS)
      File.write(shifted, MAGIC_ARRAY_CORPUS_SHIFTED)
      $VERBOSE = nil
      load source
      old_block = MagicArrayCorpus::PROC
      load shifted
      new_block = MagicArrayCorpus::PROC
      other = MagicArrayCorpus::OTHER
      concern_entry = Callback.new(:before, other)
      old_entry = Callback.new(:before, old_block)
      new_entry = Callback.new(:before, new_block)
      klass = callback_class
      klass.__callbacks = { save: Chain.new(concern_entry, old_entry, new_entry) }

      Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern_entry, old_entry] } }, [source, shifted])

      assert_same_list [concern_entry, new_entry], klass.__callbacks[:save]
    end
  ensure
    $VERBOSE = verbose if defined?(verbose)
    Object.send(:remove_const, :MagicArrayCorpus) if Object.const_defined?(:MagicArrayCorpus, false)
  end

  # Two class bodies, one of which records the file path and a new object.
  FILE_PATH_CORPUS = <<~RUBY
    module FilePathCorpus
      token = Object.new
      PROC = proc { log(__FILE__, token) }
      OTHER = proc { stamp }
    end
  RUBY

  # The same callbacks with a line inserted above them, as a mutant can.
  # The module name stays, so Ruby's block label stays too.
  FILE_PATH_CORPUS_SHIFTED = <<~RUBY
    module FilePathCorpus
      # a mutant inserted this line
      token = Object.new
      PROC = proc { log(__FILE__, token) }
      OTHER = proc { stamp }
    end
  RUBY

  # A rescued callback and an ensured callback, then the same with a line
  # inserted above them.
  RESCUE_CORPUS = <<~RUBY
    module RescueCorpus
      token = Object.new
      PROC = proc { update_audit(token) rescue nil }
      ENSURED = proc do
        update_audit(token)
      ensure
        stamp
      end
      OTHER = proc { stamp }
    end
  RUBY

  # The module name stays, so the block label stays. The inserted line moves
  # the rescue and ensure bodies.
  RESCUE_CORPUS_SHIFTED = <<~RUBY
    module RescueCorpus
      # a mutant inserted this line
      token = Object.new
      PROC = proc { update_audit(token) rescue nil }
      ENSURED = proc do
        update_audit(token)
      ensure
        stamp
      end
      OTHER = proc { stamp }
    end
  RUBY

  # A callback registered from a method, then the same method with the block
  # body changed, as a mutant of that method does.
  MUTATED_CORPUS = <<~RUBY
    module MutatedCorpus
      def self.blocks
        [proc { audit }, proc { concern_only }]
      end

      def self.other
        proc { stamp }
      end
    end
  RUBY

  MUTATED_CORPUS_CHANGED = <<~RUBY
    module MutatedCorpus
      def self.blocks
        [proc { audit_changed }, proc { concern_only }]
      end

      def self.other
        proc { stamp }
      end
    end
  RUBY

  # A block whose value is an array headed by the instruction-sequence magic.
  MAGIC_ARRAY_CORPUS = <<~'RUBY'
    module MagicArrayCorpus
      PROC = proc { ["YARVInstructionSequence/SimpleDataFormat", 1, 2, 3, { a: 1 }, "label"] }
      OTHER = proc { stamp }
    end
  RUBY

  MAGIC_ARRAY_CORPUS_SHIFTED = <<~'RUBY'
    module MagicArrayCorpus
      # a mutant inserted this line
      PROC = proc { ["YARVInstructionSequence/SimpleDataFormat", 1, 2, 3, { a: 1 }, "label"] }
      OTHER = proc { stamp }
    end
  RUBY

  # A callback object with no instance variables.
  class BareCallback
    def call = nil
  end

  # Real `before_save(&:name)` names, including operators and names that need
  # quotes. Each must pair with itself and not with `:concern_hook`.
  SYMBOL_NAMES = (%i[
    normalize validate touch save destroy create update lock unlock
    changed? valid? invalid? persisted? new_record? draft? published?
    admin? blank? present? to_s to_i to_a hash eql? freeze
    + - * / % [] []= ! ~ <=> == ===
  ] + [:"foo-bar", :"a b", :"x)", :"", :"with space"]).freeze

  # Option hashes real validators take. The repeat changes a value and keeps
  # the names. `presence:` stands in for the concern when the body uses
  # something else, and `absence:` when the body already uses `presence:`.
  OPTION_SHAPES = [
    { presence: true },
    { absence: true },
    { uniqueness: true },
    { acceptance: true },
    { confirmation: true },
    { minimum: 2 },
    { maximum: 8 },
    { is: 4 },
    { in: %w[draft published] },
    { within: (1..3) },
    { with: /\A[a-z]+\z/ },
    { greater_than: 0 },
    { greater_than_or_equal_to: 0 },
    { less_than: 10 },
    { less_than_or_equal_to: 10 },
    { only_integer: true },
    { allow_nil: true, minimum: 1 },
    { allow_blank: true, maximum: 20 },
    { if: :draft?, minimum: 1 },
    { unless: :published?, maximum: 5 },
    { message: "taken" },
    { too_short: "short", minimum: 3 },
    { length: { minimum: 2 } },
    { numericality: { greater_than: 0, only_integer: true } }
  ].freeze

  # Attribute lists from model validations.
  ATTRIBUTES = [%i[title], %i[name], %i[slug], %i[weight], %i[status], %i[title name]].freeze

  # @return [Array<Hash>] rows whose new entry must replace the old one.
  def pair_rows
    rows = SYMBOL_NAMES.map { |name| symbol_row(name) }
    rows.concat(block_rows)
    rows.concat(capture_rows)
    rows.concat(option_rows)
    rows.concat(attribute_rows)
    rows.concat(condition_rows)
    rows << { label: "same callback class", entries: class_entries(same_class: true) }
    rows
  end

  # @return [Array<Hash>] rows whose three entries must all stay.
  def keep_rows
    rows = %i[normalize touch valid? + []].map { |name| same_symbol_row(name) }
    rows.concat([
                  { label: "same minimum:", entries: validator_entries({ minimum: 1 }, { minimum: 2 }, { minimum: 3 }) },
                  { label: "same maximum:", entries: validator_entries({ maximum: 1 }, { maximum: 2 }, { maximum: 9 }) },
                  { label: "same greater_than:", entries: validator_entries({ greater_than: 0 }, { greater_than: 1 }, { greater_than: 4 }) },
                  { label: "same in:", entries: validator_entries({ in: %w[a] }, { in: %w[a b] }, { in: %w[a b c] }) },
                  { label: "same message:", entries: validator_entries({ message: "a" }, { message: "b" }, { message: "c" }) }
                ])
    rows.concat([0, 3, 7].map { |index| { label: "same block #{index}", entries: identical_block_entries(index) } })
    rows << { label: "same block code, new capture", entries: capture_entries }
    rows << { label: "stateless object, same condition", entries: bare_entries(:published?, :published?) }
    rows << { label: "stateless object, no condition", entries: bare_entries(nil, nil) }
    rows << { label: "fresh anonymous class", entries: class_entries(same_class: false) }
    rows
  end

  # @param name [Symbol]
  # @return [Hash]
  def same_symbol_row(name)
    evict_symbol_proc_cache
    concern = name.to_proc
    evict_symbol_proc_cache
    own = name.to_proc
    evict_symbol_proc_cache
    again = name.to_proc
    refute_same own, again, name.inspect
    { label: "same &:#{name}", entries: [Callback.new(:before, concern), Callback.new(:before, own), Callback.new(:before, again)] }
  end

  # @param name [Symbol]
  # @return [Hash]
  def symbol_row(name)
    concern = :concern_hook.to_proc
    old_proc = name.to_proc
    evict_symbol_proc_cache
    new_proc = name.to_proc
    refute_same old_proc, new_proc, name.inspect
    { label: "&:#{name}", entries: [Callback.new(:before, concern), Callback.new(:before, old_proc), Callback.new(:before, new_proc)] }
  end

  # Class-body blocks. One method builds every shape, including the concern's
  # `concern_only` block, so they share a label and only the code tells them
  # apart.
  #
  # @return [Array<Proc>]
  def callback_blocks
    [
      proc { concern_only },
      proc { throw :abort },
      proc { |record| record.errors.add(:base, :invalid) },
      proc { self.updated_at = Time.current },
      proc { |record| record.title.blank? },
      proc { |record| record.published? },
      proc { normalize },
      proc { |record| record.normalize },
      proc { stamp },
      proc { |record| record.touch },
      proc { valid? },
      proc { |record| record.draft? && record.title },
      proc { |record| record.status == "open" },
      proc { |record| record.comments.empty? },
      proc { |record| record.weight > 10 },
      proc { |record| record.weight >= 10 },
      proc { |record| !record.locked? },
      proc { |record| record.name.to_s.downcase },
      proc { |record| record.slug.presence },
      proc { |record| Array(record.tags).include?("a") },
      proc { |record| record.errors.clear },
      proc { |record| record.readonly! },
      proc { |record| record.assign_attributes(title: record.title.to_s.strip) },
      proc { |record| record.notify },
      proc { draft? }
    ]
  end

  # @return [Array<Hash>]
  def block_rows
    callback_blocks.each_with_index.filter_map do |_block, index|
      next if index.zero?

      { label: "block #{index}", entries: [Callback.new(:before, callback_blocks[0]), Callback.new(:before, callback_blocks[index]), Callback.new(:before, callback_blocks[index])] }
    end
  end

  # @param index [Integer]
  # @return [Array<Callback>]
  def identical_block_entries(index)
    [
      Callback.new(:before, callback_blocks[index]),
      Callback.new(:before, callback_blocks[index]),
      Callback.new(:before, callback_blocks[index])
    ]
  end

  # A new object, a time and a random value, closed over by different blocks.
  # The `:stable` block shares this method, so it shares their label.
  #
  # @return [Array<Proc>]
  def capture_blocks
    object = Object.new
    time = Time.now
    number = rand
    [
      proc { :stable },
      proc { object },
      proc { [object, object] },
      proc { time },
      proc { time.to_i },
      proc { number },
      proc { number.zero? },
      proc { |record| record.id == object },
      proc { |record| record.created_at > time }
    ]
  end

  # @return [Array<Hash>]
  def capture_rows
    capture_blocks.each_with_index.filter_map do |_block, index|
      next if index.zero?

      { label: "capture #{index}", entries: [Callback.new(:before, capture_blocks[0]), *capture_pair(index)] }
    end
  end

  # @param index [Integer]
  # @return [Array<Callback>]
  def capture_pair(index)
    [Callback.new(:before, capture_blocks[index]), Callback.new(:before, capture_blocks[index])]
  end

  # Three copies of the first capturing block. The captures differ on each
  # call and the code does not, so the concern stays in the same bucket.
  #
  # @return [Array<Callback>]
  def capture_entries
    [
      Callback.new(:before, capture_blocks[1]),
      Callback.new(:before, capture_blocks[1]),
      Callback.new(:before, capture_blocks[1])
    ]
  end

  # @return [Array<Hash>]
  def option_rows
    OPTION_SHAPES.map do |shape|
      concern_shape = shape.key?(:presence) ? { absence: true } : { presence: true }
      { label: "options #{shape.keys.join('+')}", entries: validator_entries(concern_shape, shape, changed_values(shape)), validators: true }
    end
  end

  # @return [Array<Hash>]
  def attribute_rows
    ATTRIBUTES.map do |attributes|
      concern = Validator.new([:body], { minimum: 1 })
      old_validator = Validator.new(attributes, { minimum: 2 })
      new_validator = Validator.new(attributes, { minimum: 9 })
      { label: "attributes #{attributes.join('+')}", entries: validator_callbacks(concern, old_validator, new_validator), validators: true }
    end
  end

  # @param concern_options [Hash]
  # @param old_options [Hash]
  # @param new_options [Hash]
  # @return [Array<Callback>]
  def validator_entries(concern_options, old_options, new_options)
    validator_callbacks(Validator.new([:title], concern_options), Validator.new([:title], old_options), Validator.new([:title], new_options))
  end

  # @param concern [Validator]
  # @param old_validator [Validator]
  # @param new_validator [Validator]
  # @return [Array<Callback>]
  def validator_callbacks(concern, old_validator, new_validator)
    [Callback.new(:before, concern), Callback.new(:before, old_validator), Callback.new(:before, new_validator)]
  end

  # @param value [Object]
  # @return [Object] `value` with leaf values changed and keys kept.
  def changed_values(value)
    case value
    when Hash then value.to_h { |key, inner| [key, changed_values(inner)] }
    when Array then value.map { |inner| changed_values(inner) }
    when Integer then value + 7
    when String then "#{value}!"
    when Regexp then /changed/
    when TrueClass, FalseClass then !value
    when Range then (value.begin + 1)..(value.end + 1)
    else value
    end
  end

  # Both condition procs are built here, so they share a label.
  #
  # @return [Array<Proc>]
  def condition_procs
    [proc { draft? }, proc { published? }]
  end

  # @return [Array<Hash>]
  def condition_rows
    [
      { label: "symbol condition", entries: bare_entries(:draft?, :published?) },
      { label: "proc condition", entries: [guarded(BareCallback.new, condition_procs[0]), guarded(BareCallback.new, condition_procs[1]), guarded(BareCallback.new, condition_procs[1])] },
      { label: "same class, symbol condition", entries: class_entries(same_class: true, concern_if: :draft?, body_if: :published?) },
      { label: "unless symbol", entries: bare_unless(:draft?, :published?) },
      { label: "unless proc", entries: [guarded(BareCallback.new, nil, unless_condition: condition_procs[0]), guarded(BareCallback.new, nil, unless_condition: condition_procs[1]), guarded(BareCallback.new, nil, unless_condition: condition_procs[1])] }
    ]
  end

  # @param concern_if [Object, nil]
  # @param body_if [Object, nil]
  # @return [Array<Callback>]
  def bare_entries(concern_if, body_if)
    [
      guarded(BareCallback.new, concern_if),
      guarded(BareCallback.new, body_if),
      guarded(BareCallback.new, body_if)
    ]
  end

  # @param same_class [Boolean]
  # @param concern_if [Object, nil]
  # @param body_if [Object, nil]
  # @return [Array<Callback>]
  def class_entries(same_class:, concern_if: nil, body_if: nil)
    stamp = Class.new
    [
      guarded(Class.new, concern_if),
      guarded(stamp, body_if),
      guarded(same_class ? stamp : Class.new, body_if)
    ]
  end

  # @param concern_unless [Object]
  # @param body_unless [Object]
  # @return [Array<Callback>]
  def bare_unless(concern_unless, body_unless)
    [
      guarded(BareCallback.new, nil, unless_condition: concern_unless),
      guarded(BareCallback.new, nil, unless_condition: body_unless),
      guarded(BareCallback.new, nil, unless_condition: body_unless)
    ]
  end

  # @param filter [Object]
  # @param condition [Object, nil]
  # @param unless_condition [Object, nil]
  # @return [Callback]
  def guarded(filter, condition, unless_condition: nil)
    callback = Callback.new(:before, filter)
    callback.instance_variable_set(:@if, [condition]) if condition
    callback.instance_variable_set(:@unless, [unless_condition]) if unless_condition
    callback
  end

  # @param label [String]
  # @param concern [Callback]
  # @param old_entry [Callback]
  # @param new_entry [Callback]
  # @param validators [Boolean]
  # @return [void]
  def assert_repeat_replaced(label, concern, old_entry, new_entry, validators: false)
    klass = chain_with(concern, old_entry, new_entry, validators: validators)

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern, old_entry] } }, [__FILE__])

    assert_same_list [concern, new_entry], klass.__callbacks[:save], label
    return unless validators

    assert_same_list [concern.filter, new_entry.filter], klass._validators[:title], label
  end

  # @param label [String]
  # @param concern [Callback]
  # @param old_entry [Callback]
  # @param new_entry [Callback]
  # @return [void]
  def assert_every_copy_stays(label, concern, old_entry, new_entry)
    klass = chain_with(concern, old_entry, new_entry, validators: false)

    Mutineer::ReloadGuards::RepeatedCallbacks.remove({ klass => { save: [concern, old_entry] } }, [__FILE__])

    assert_same_list [concern, old_entry, new_entry], klass.__callbacks[:save], label
  end

  # @param concern [Callback]
  # @param old_entry [Callback]
  # @param new_entry [Callback]
  # @param validators [Boolean]
  # @return [Class]
  def chain_with(concern, old_entry, new_entry, validators:)
    klass = callback_class
    klass.__callbacks = { save: Chain.new(concern, old_entry, new_entry) }
    klass._validators = { title: [concern.filter, old_entry.filter, new_entry.filter] } if validators
    klass
  end
end
