# frozen_string_literal: true

# Runs inside the Rails fixture bundle. Uses real ActiveSupport callbacks,
# then Mutineer's reload guard, and prints one JSON object.
require "json"
require "active_support"
require "active_support/callbacks"
require "active_support/concern"
require "active_model"
require "tmpdir"
require "mutineer/reload_guards"
require "mutineer/concern_blocks"

# A class ActiveSupport can hang a :save callback chain on.
class CallbackHost
  include ActiveSupport::Callbacks
  define_callbacks :save

  def self.check(*) = nil
end

# #504: concerns that add a callback to a chain the including class defines
# itself. They live outside the reloaded file, as in an app, so their
# `included` blocks do not run again.
module OwnStampsProbe
  extend ActiveSupport::Concern

  included do
    before_save :stamp
  end
end

# Adds the same `&:stamp` block callback that the class body adds.
module OwnDoubledStampsProbe
  extend ActiveSupport::Concern

  included do
    before_save(&:stamp)
  end
end

# Adds a model callback to a chain `define_model_callbacks` defines.
module OwnModelStampsProbe
  extend ActiveSupport::Concern

  included do
    before_create :stamp
  end
end

module RailsCallbackRestoreProbe
  module_function

  # The classes of probe P4 in the #504 plan. Each body calls
  # `define_callbacks` itself, so a reload ran it again and cleared the chain.
  OWN_CHAIN_FILE = <<~RUBY
    class OwnChain
      include ActiveSupport::Callbacks
      define_callbacks :save

      def self.before_save(*args, &block) = set_callback(:save, :before, *args, &block)

      include OwnStampsProbe
      before_save { |own| own.log << :own }

      def log = (@log ||= [])

      def stamp = log << :stamp

      def save = run_callbacks(:save) { log }
    end

    class OwnDoubled
      include ActiveSupport::Callbacks
      define_callbacks :save

      def self.before_save(*args, &block) = set_callback(:save, :before, *args, &block)

      include OwnDoubledStampsProbe
      before_save(&:stamp)

      def stamp = nil
    end

    class OwnModel
      extend ActiveModel::Callbacks
      define_model_callbacks :create

      include OwnModelStampsProbe
      before_create { nil }

      def stamp = nil
    end
  RUBY

  # Loads the classes, defines a subclass in "another file", then loads the
  # same text again through the mutant load. Returns the chain sizes and the
  # `save` log before and after, and the classes the growth log names.
  def own_chains
    Dir.mktmpdir do |dir|
      file = File.join(dir, "own_chain.rb")
      File.write(file, OWN_CHAIN_FILE)
      load file
      Object.const_set(:OwnChild, Class.new(OwnChain) { before_save :child_cb })
      OwnChild.define_method(:child_cb) { log << :child }
      counts = -> { { "OwnChain" => OwnChain.__callbacks[:save].to_a.size, "OwnChild" => OwnChild.__callbacks[:save].to_a.size,
                      "OwnDoubled" => OwnDoubled.__callbacks[:save].to_a.size,
                      "OwnModel" => OwnModel.__callbacks[:create].to_a.size } }
      before = counts.call
      log_before = OwnChain.new.save.map(&:to_s)
      growth = File.join(dir, "growth.log")
      File.write(growth, "")
      Mutineer::ReloadGuards.callback_growth_log = growth
      Mutineer::ConcernBlocks.load_mutant(file, file)
      grown = File.read(growth).lines.map { |line| line.split("\t").first.undump }
      { "before" => before, "after" => counts.call, "log_before" => log_before,
        "log_after" => OwnChain.new.save.map(&:to_s), "child_log_after" => OwnChild.new.save.map(&:to_s),
        "grown" => grown }
    end
  end

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
    puts JSON.generate("proc_skip" => proc_skip, "independent_symbol" => independent_symbol, "own_chains" => own_chains)
  end
end

RailsCallbackRestoreProbe.run
