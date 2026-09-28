# frozen_string_literal: true

module Mutineer
  # Realpath-based path normalization against a project root. Shared by the
  # coverage cache (map keys) and mutant ids (the path hashed into each id), so
  # `lib/x.rb`, `./lib/x.rb`, an absolute path and a path through a symlinked
  # root all resolve to the same key. Realpaths on both sides also absorb the
  # macOS `/var` vs `/private/var` alias.
  module ProjectPath
    module_function

    # Path of `path` relative to the real project root. A path outside the root
    # comes back as its absolute real path.
    #
    # @param path [String] relative (to `root`) or absolute path.
    # @param root [String] project root.
    # @return [String] root-relative path, or an absolute path when outside `root`.
    def relative(path, root)
      abs = absolute(path, root)
      real_root = root_real(root)
      prefix = real_root.end_with?("/") ? real_root : "#{real_root}/"
      return abs unless abs.start_with?(prefix)

      abs.delete_prefix(prefix)
    end

    # Expands `path` against `root`, resolved to its real path when it exists.
    #
    # @param path [String] relative (to `root`) or absolute path.
    # @param root [String] project root.
    # @return [String] absolute path.
    def absolute(path, root)
      raw = File.absolute_path?(path) ? path : File.expand_path(path, root)
      realpath_if_exists(raw)
    end

    # Canonical project root (`/var` vs `/private/var`).
    #
    # @param root [String] project root.
    # @return [String] realpath of the root when it exists, else its expanded path.
    def root_real(root)
      File.realpath(File.expand_path(root))
    rescue Errno::ENOENT
      File.expand_path(root)
    end

    # Real path when the file exists, otherwise `path` unchanged.
    #
    # @param path [String] absolute or relative path.
    # @return [String]
    def realpath_if_exists(path)
      File.exist?(path) ? File.realpath(path) : path
    end
  end
end
