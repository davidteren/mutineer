# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/reload_guards"

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
    Object.const_set(:Rails, Module.new.tap { |r| r.define_singleton_method(:autoloaders) { [unmanaged, main] } })

    Mutineer::ReloadGuards.load_original("app/models/a.rb")
    path = File.expand_path("app/models/a.rb")
    assert_equal [[:once, path], [:main, path]], asked
  ensure
    Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
    Object.send(:remove_const, :Zeitwerk) if Object.const_defined?(:Zeitwerk, false)
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
end
