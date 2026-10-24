# frozen_string_literal: true

module Mutineer
  # Lets the reload strategy load a concern file a second time (#256).
  #
  # ActiveSupport::Concern stores an `included` or `prepended` block once. A
  # second block with another `source_location` raises
  # `MultipleIncludedBlocks` (or `MultiplePrependBlocks`). Rails reloads keep
  # the file's path, but a mutant loads from a temp file beside it, so every
  # mutant of a concern with such a block would error. {.forget} removes the
  # stored blocks that the source file defined, so the mutant's load stores
  # its own. {.replace} wraps the load and puts back any block the load did not
  # store again, such as one under an `unless defined?` guard.
  #
  # ActiveSupport does not run the block again in a class that already includes
  # the concern, so that class keeps what the original block defined. For a def
  # in the block, the mutant file also passes the mutated def to
  # {.store_hook_def}, just before the `included` or `prepended` call, and
  # {.place_hook_def} then loads only that def into each class that has the
  # method (#297). Nothing else in the block runs again. Discovery decides which
  # defs can be placed this way (see {Subject#unplaceable?}).
  #
  # Call it only in a forked child that loads the mutant. Without
  # ActiveSupport, {.replace} and {.forget} do nothing; {.store_hook_def} and
  # {.place_hook_def} work without it.
  #
  # Stdlib-only, so the app-side daemon can load it.
  module ConcernBlocks
    # Where ActiveSupport::Concern stores each block.
    STORED_BLOCKS = %i[@_included_block @_prepended_block].freeze

    # Forgets the source file's stored blocks, runs the block that loads the
    # mutant, then puts back each forgotten block the load did not store again.
    # A concern the mutant's load skips (an `unless defined?` guard) keeps its
    # original block, so a class that includes it during the tests still gets it.
    #
    # @param source_file [String] the file the mutant replaces.
    # @yield the mutant's load.
    # @return [Object] what the block returns.
    def self.replace(source_file)
      forgotten = forget(source_file)
      yield
    ensure
      forgotten&.each do |concern, name, block|
        concern.instance_variable_set(name, block) unless concern.instance_variable_defined?(name)
      end
    end

    # Removes every stored `included` and `prepended` block that the source
    # file defined, from every concern. Blocks from other files stay.
    #
    # @param source_file [String] the file the mutant replaces.
    # @return [Array<Array(Module, Symbol, Proc)>] each concern, where it stored
    #   the block, and the block removed.
    def self.forget(source_file)
      return [] unless defined?(::ActiveSupport::Concern)

      path = real_path(source_file)
      forgotten = []
      ObjectSpace.each_object(::ActiveSupport::Concern) do |concern|
        STORED_BLOCKS.each do |name|
          next unless concern.instance_variable_defined?(name)

          block = concern.instance_variable_get(name)
          file = block.source_location&.first
          next unless file && real_path(file) == path

          concern.remove_instance_variable(name)
          forgotten << [concern, name, block]
        end
      end
      forgotten
    end

    # Keeps the mutated hook-block def for {.place_hook_def}. The mutant file
    # calls it in the concern's body, just before the hook call, so the block has
    # the same constant scope as the hook block (#297).
    #
    # @yield the mutated def, run later with `class_eval` in each owner.
    # @return [nil]
    def self.store_hook_def(&block)
      @hook_def = block
      nil
    end

    # Takes the def {.store_hook_def} kept, clears it, and runs it with
    # `class_eval` in each module whose own method came from the original def
    # (see {.owners}), so that module gets the mutated method and nothing else in
    # the block runs again. Each owner keeps the method's visibility. A class
    # that includes the concern later gets the mutant from the stored block.
    #
    # @param source_file [String] the file the mutant replaces.
    # @param line [Integer] the original def's first line.
    # @param name [Symbol] the method name.
    # @param singleton [Boolean] true for a class method.
    # @raise [RuntimeError] when no def was kept (the mutant file did not reach
    #   its hook call), or when a module keeps the original under another name
    #   (see {.aliases}); the child then scores the mutant `error`.
    # @return [Integer] how many owners got the mutated def.
    def self.place_hook_def(source_file:, line:, name:, singleton:)
      block = @hook_def
      @hook_def = nil
      where = "mutineer: could not place the mutant of #{name} (#{source_file}:#{line})"
      unless block
        raise "#{where}: the mutant file did not reach its included or prepended call. " \
              "This is a mutineer bug; please report it."
      end

      # ponytail: one ObjectSpace walk per mutant (about 11 ms with Rails loaded);
      # index modules by method name if a large app makes it slow.
      modules = ObjectSpace.each_object(Module).to_a
      found = owners(modules, source_file: source_file, line: line, name: name, singleton: singleton)
      mod, other = aliases(modules, source_file: source_file, line: line, name: name, singleton: singleton).first
      if mod
        raise "#{where}: #{mod.inspect}#{singleton ? "." : "#"}#{other} is an alias of it and keeps the " \
              "original method, so the mutant scores error."
      end

      found.each do |owner|
        target = singleton ? owner.singleton_class : owner
        visibility = if target.private_method_defined?(name, false) then :private
                     elsif target.protected_method_defined?(name, false) then :protected
                     end
        owner.class_eval(&block) # a `def` in the block defines public
        target.send(visibility, name) if visibility
      end
      found.size
    end

    # Each module whose own method `name` (its singleton class's, for a class
    # method) has the original def's file and line: every place the original
    # block defined it. A subclass that overrides the method, or a class that
    # only inherits it, is not one.
    #
    # @param modules [Array<Module>] every module, including singleton classes
    #   into which a concern can be included.
    # @param source_file [String] the file the mutant replaces.
    # @param line [Integer] the original def's first line.
    # @param name [Symbol] the method name.
    # @param singleton [Boolean] true for a class method.
    # @return [Array<Module>]
    def self.owners(modules, source_file:, line:, name:, singleton:)
      path = real_path(source_file)
      modules.select { |mod| own_method_at?(singleton ? mod.singleton_class : mod, name, path, line) }
    end

    # Each other name any module has for the original def: an alias made
    # outside the block. Check independently of {.owners}: a wrapper can replace
    # the original name while its alias keeps the original body, so the mutant
    # could falsely survive even when no current-name owner remains.
    #
    # @param modules [Array<Module>] every module, including singleton classes.
    # @param source_file [String] the file the mutant replaces.
    # @param line [Integer] the original def's first line.
    # @param name [Symbol] the method name.
    # @param singleton [Boolean] true for a class method.
    # @return [Array<Array(Module, Symbol)>] each module and its alias name.
    def self.aliases(modules, source_file:, line:, name:, singleton:)
      path = real_path(source_file)
      modules.flat_map do |mod|
        target = singleton ? mod.singleton_class : mod
        (target.instance_methods(false) + target.private_instance_methods(false)).filter_map do |other|
          [mod, other] if other != name && own_method_at?(target, other, path, line)
        end
      end
    end

    # True when the module's own method `name` starts at this file and line.
    # A prepended method can hide it from `instance_method`, so follow `super`
    # until the lookup reaches the method whose owner is the module itself.
    #
    # @param target [Module] the module or singleton class to read.
    # @param name [Symbol] the method name.
    # @param path [String] the source file's real path.
    # @param line [Integer] the def's first line.
    # @return [Boolean]
    def self.own_method_at?(target, name, path, line)
      return false unless target.method_defined?(name, false) || target.private_method_defined?(name, false)

      method = target.instance_method(name)
      method = method.super_method while method && !method.owner.equal?(target)
      return false unless method

      file, def_line = method.source_location
      def_line == line && !file.nil? && real_path(file) == path
    end

    # The file's real path, so a symlinked or relative path matches the path
    # Ruby recorded when it loaded the file.
    #
    # @param file [String] a file path.
    # @return [String]
    def self.real_path(file)
      File.realpath(file)
    rescue SystemCallError
      File.expand_path(file)
    end
  end
end
