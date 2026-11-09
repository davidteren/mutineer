# frozen_string_literal: true

module Mutineer
  # Lets the reload strategy run a Rails class body a second time.
  #
  # Reload `load`s the mutant file over a class that is already defined, so the
  # class body runs again. Two Rails macros refuse that:
  #
  # - `enum` raises because the enum's methods already exist (#378).
  # - `skip_callback` (and `skip_before_action`, which calls it) raises because
  #   the first run already removed the callback (#384).
  #
  # While {.during_load} runs, an `enum` the class had before the load skips
  # its conflict check, and `skip_callback` does not raise for a callback that
  # only the superclass still has.
  # The original file ran the same macros once with the full checks, so the
  # second run repeats work Rails already accepted. Outside the load, for
  # example while the tests run, both macros check as usual.
  #
  # {.during_load} also loads the original file first when the app autoloads it
  # and nothing has loaded it yet (#383). Ruby would do that anyway when the
  # mutant reopens the constant, but inside the load, after
  # {ConcernBlocks.forget}, so the concern's original `included` block would
  # come back and the mutant's block would raise `MultipleIncludedBlocks`.
  #
  # Call it only in a forked child that loads the mutant: it prepends onto
  # Rails modules in that process. Without Rails it only runs the block.
  #
  # Stdlib-only, so the app-side daemon can load it.
  module ReloadGuards
    # Skips the conflict check for an enum the class defined before the mutant
    # load began, during that load only.
    module EnumRedeclaration
      private

      # @param enum_name [Symbol, String] the enum being declared.
      # @return [void]
      def detect_enum_conflict!(enum_name, *)
        return if ReloadGuards.loading? && ReloadGuards.enum_existed?(self, enum_name)

        super
      end
    end

    # Makes a repeated skip a no-op, during a mutant load only. A skip counts
    # as repeated when the superclass still has every callback it names: the
    # first run of the class body removed them from this class only. Any other
    # skip keeps Rails' check, so a wrong one still raises (scored `error`).
    module CallbackReskipping
      # @param name [Symbol] the callback chain, such as `:save`.
      # @param filter_list [Array] the kind, the filters, and options.
      # @return [void]
      def skip_callback(name, *filter_list, &block)
        return super unless ReloadGuards.loading?

        options = filter_list.last.is_a?(Hash) ? filter_list.pop : {}
        options = { raise: false }.merge(options) if ReloadGuards.inherited_callbacks?(self, name, *filter_list)
        super(name, *filter_list, options, &block)
      end
    end

    # True while a mutant file loads.
    #
    # @return [Boolean]
    def self.loading?
      @loading == true
    end

    # Loads the original file if the app autoloads it, then runs the block that
    # loads the mutant with the guards on.
    #
    # @param source_file [String] the file the mutant replaces.
    # @yield the mutant's load.
    # @return [Object] what the block returns.
    def self.during_load(source_file)
      install!
      load_original(source_file)
      @enums_before_load = {}
      @loading = true
      yield
    ensure
      @loading = false
    end

    # Whether `klass` had the enum before this load. Rails records a new enum
    # after its first conflict check, so the answer is read once, at the first
    # check of each enum, and kept for the rest of the load.
    #
    # @param klass [Class] the model declaring the enum.
    # @param enum_name [Symbol, String] the enum being declared.
    # @return [Boolean]
    def self.enum_existed?(klass, enum_name)
      key = [klass, enum_name.to_s]
      @enums_before_load.fetch(key) { @enums_before_load[key] = klass.defined_enums.key?(key.last) }
    end

    # True when `klass`'s superclass has a `kind` callback on chain `name` for
    # every filter. With no filters there is nothing to compare, so false.
    #
    # @param klass [Class] the class calling `skip_callback`.
    # @param name [Symbol] the callback chain, such as `:save`.
    # @param kind [Symbol] `:before`, `:after` or `:around`.
    # @param filters [Array] the callbacks to skip, usually method names.
    # @return [Boolean]
    def self.inherited_callbacks?(klass, name, kind = nil, *filters)
      parent = klass.superclass
      return false if filters.empty? || !parent.respond_to?(:__callbacks)

      chain = parent.__callbacks[name] or return false
      filters.all? { |filter| chain.any? { |callback| callback.kind == kind && callback.filter == filter } }
    end

    # Prepends the guards once, onto the Rails modules this process has loaded.
    #
    # @return [void]
    def self.install!
      prepend_once(::ActiveRecord::Enum, EnumRedeclaration) if defined?(::ActiveRecord::Enum)
      return unless defined?(::ActiveSupport::Callbacks::ClassMethods)

      prepend_once(::ActiveSupport::Callbacks::ClassMethods, CallbackReskipping)
    end

    # @param target [Module] the Rails module.
    # @param guard [Module] the guard to put in front of it.
    # @return [void]
    def self.prepend_once(target, guard)
      target.prepend(guard) unless target.ancestors.include?(guard)
    end

    # Asks each Rails autoloader for the constant `source_file` defines. A
    # loader that does not manage the file raises `Zeitwerk::Error`; the next
    # one is asked. A file already loaded only costs a constant lookup.
    #
    # @param source_file [String] the file the mutant replaces.
    # @return [void]
    def self.load_original(source_file)
      return unless defined?(::Rails) && ::Rails.respond_to?(:autoloaders) && defined?(::Zeitwerk::Error)

      ::Rails.autoloaders.each do |loader|
        next unless loader.respond_to?(:load_file)

        begin
          loader.load_file(File.expand_path(source_file))
          return
        rescue ::Zeitwerk::Error
          next
        end
      end
    end
  end
end
