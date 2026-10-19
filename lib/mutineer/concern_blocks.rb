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
  # its own. A class that already includes the concern keeps what the original
  # block defined in it: ActiveSupport does not run the block there again.
  # Discovery marks the defs in these blocks (see {Subject#unplaceable?}).
  #
  # Call it only in a forked child that loads the mutant. Without
  # ActiveSupport it does nothing.
  #
  # Stdlib-only, so the app-side daemon can load it.
  module ConcernBlocks
    # Where ActiveSupport::Concern stores each block.
    STORED_BLOCKS = %i[@_included_block @_prepended_block].freeze

    # Removes every stored `included` and `prepended` block that the source
    # file defined, from every concern. Blocks from other files stay.
    #
    # @param source_file [String] the file the mutant replaces.
    # @return [void]
    def self.forget(source_file)
      return unless defined?(::ActiveSupport::Concern)

      path = real_path(source_file)
      ObjectSpace.each_object(::ActiveSupport::Concern) do |concern|
        STORED_BLOCKS.each do |name|
          next unless concern.instance_variable_defined?(name)

          file = concern.instance_variable_get(name).source_location&.first
          concern.remove_instance_variable(name) if file && real_path(file) == path
        end
      end
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
