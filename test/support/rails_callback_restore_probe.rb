# frozen_string_literal: true

# Runs inside the Rails fixture bundle. Uses real ActiveSupport callbacks,
# then Mutineer's reload guard, and prints one JSON object.
require "json"
require "active_support"
require "active_support/callbacks"
require "mutineer/reload_guards"

# A class ActiveSupport can hang a :save callback chain on.
class CallbackHost
  include ActiveSupport::Callbacks
  define_callbacks :save

  def self.check(*) = nil
end

module RailsCallbackRestoreProbe
  module_function

  def conditions(callback)
    [callback.instance_variable_get(:@if).to_a, callback.instance_variable_get(:@unless).to_a]
  end

  def sole(klass)
    chain = klass.__callbacks[:save].to_a
    raise "expected one callback on #{klass}, got #{chain.size}" unless chain.size == 1

    chain.fetch(0)
  end

  # Parent `if:` is a Proc. The subclass skip adds `if: :express?`, which
  # Rails stores on `@unless`. After the parent callback is set again with a
  # new Proc, the subclass must run that Proc, and still skip on `:express?`.
  def proc_skip
    old_proc = -> { false }
    new_proc = -> { true }
    parent = Class.new(CallbackHost)
    parent.set_callback(:save, :before, :check, if: old_proc)
    child = Class.new(parent)
    child.skip_callback(:save, :before, :check, if: :express?)
    before = Mutineer::ReloadGuards::RepeatedCallbacks.snapshot
    parent.set_callback(:save, :before, :check, if: new_proc)
    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])
    ifs, unlesses = conditions(sole(child))
    {
      "new_proc" => ifs.any? { |item| item.equal?(new_proc) },
      "old_proc" => ifs.any? { |item| item.equal?(old_proc) },
      "express" => unlesses.any? { |item| item.equal?(:express?) }
    }
  end

  # The subclass declared its own callback with the same symbol. A parent
  # reload must not replace that symbol.
  def independent_symbol
    parent = Class.new(CallbackHost)
    parent.set_callback(:save, :before, :check, if: :active?)
    exact = Class.new(parent)
    exact.set_callback(:save, :before, :check, if: :active?)
    longer = Class.new(parent)
    longer.set_callback(:save, :before, :check, if: [:active?, :mine?])
    before = Mutineer::ReloadGuards::RepeatedCallbacks.snapshot
    parent.set_callback(:save, :before, :check, if: :ready?)
    Mutineer::ReloadGuards::RepeatedCallbacks.remove(before, [__FILE__])
    exact_if, = conditions(sole(exact))
    longer_if, = conditions(sole(longer))
    {
      "exact_active" => exact_if.any? { |item| item.equal?(:active?) },
      "exact_ready" => exact_if.any? { |item| item.equal?(:ready?) },
      "longer" => longer_if.map { |item| item.is_a?(Symbol) ? item.to_s : "proc" }
    }
  end

  def run
    puts JSON.generate("proc_skip" => proc_skip, "independent_symbol" => independent_symbol)
  end
end

RailsCallbackRestoreProbe.run
