# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/reload_guards"

# #378, #384: the guards relax two Rails macros only while a mutant loads.
# Stand-ins replace the Rails modules, so the suite stays Rails-free.
class ReloadGuardsTest < Minitest::Test
  # Stands in for ActiveRecord::Enum's conflict check.
  class EnumHost
    class << self
      def defined_enums = { "status" => {} }
      def declare(name) = detect_enum_conflict!(name, :"#{name}?")

      private

      def detect_enum_conflict!(name, _method) = raise(ArgumentError, "conflict: #{name}")
    end
    singleton_class.prepend(Mutineer::ReloadGuards::EnumRedeclaration)
  end

  # Stands in for ActiveSupport::Callbacks::ClassMethods#skip_callback.
  class CallbackHost
    class << self
      attr_reader :options

      def skip_callback(_name, *filters) = (@options = filters.last.is_a?(Hash) ? filters.last : {})
    end
    singleton_class.prepend(Mutineer::ReloadGuards::CallbackReskipping)
  end

  def test_an_enum_the_class_has_skips_its_conflict_check_only_during_a_load
    assert_raises(ArgumentError) { EnumHost.declare(:status) }
    Mutineer::ReloadGuards.during_load("unused.rb") { EnumHost.declare(:status) }
    assert_raises(ArgumentError) { EnumHost.declare(:status) }
  end

  def test_a_new_enum_keeps_its_conflict_check_during_a_load
    assert_raises(ArgumentError) do
      Mutineer::ReloadGuards.during_load("unused.rb") { EnumHost.declare(:kind) }
    end
  end

  def test_skip_callback_does_not_raise_for_a_missing_callback_only_during_a_load
    CallbackHost.skip_callback(:save, :before, :check)
    assert_equal({}, CallbackHost.options)

    Mutineer::ReloadGuards.during_load("unused.rb") { CallbackHost.skip_callback(:save, :before, :check, if: :x) }
    assert_equal({ raise: false, if: :x }, CallbackHost.options)
  end

  def test_an_explicit_raise_option_wins_during_a_load
    Mutineer::ReloadGuards.during_load("unused.rb") { CallbackHost.skip_callback(:save, :before, :check, raise: true) }
    assert_equal({ raise: true }, CallbackHost.options)
  end

  def test_the_guard_turns_off_when_the_load_raises
    assert_raises(RuntimeError) { Mutineer::ReloadGuards.during_load("unused.rb") { raise "boom" } }
    refute Mutineer::ReloadGuards.loading?
  end
end
