# frozen_string_literal: true

require "open3"
require "digest"
require_relative "fs_path"

module Mutineer
  # Reads the state of the git work tree that holds a project root, for the
  # coverage cache (#595). It lists paths. It never reads hunks: that is
  # {ChangedLines}. Every method fails closed: a git failure is `nil`, never
  # "no change". It needs only the standard library, so the daemon can load it
  # before the app boots.
  module WorkTree
    # Variables that point git at another repository, work tree or index.
    # Every git command here runs without them, so the answer is about the
    # project root and nothing else.
    GIT_ENV = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
                 GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE].to_h { |name| [name, nil] }.freeze

    module_function

    # The work-tree record the coverage cache saves: the commit that is
    # checked out and a fingerprint of each path that differs from it.
    #
    # @param root [String] project root.
    # @return [Hash] `"commit"` (String, or nil when git gives none) and
    #   `"dirty"` (path relative to `root` => fingerprint, or nil for a path
    #   that never matches).
    def record(root)
      commit = head(root)
      paths = commit ? changed_since(commit, root) : nil
      return { "commit" => nil, "dirty" => {} } unless paths

      utf8, other = paths.partition { |rel| rel.encoding == Encoding::UTF_8 || rel.ascii_only? }
      dirty = utf8.to_h { |rel| [rel, fingerprint(root, rel)] }
      # JSON cannot hold a path that is not UTF-8. Its entry never matches.
      other.each { |rel| dirty[rel.dup.force_encoding(Encoding::UTF_8).scrub("?")] = nil }
      { "commit" => commit, "dirty" => dirty }
    end

    # Fingerprint of a work-tree path: its mode and content. It is not the
    # value of `CoverageMap#file_fingerprint`: never compare the two. Nil never
    # matches: a folder (a submodule or a nested repository) or a file that
    # cannot be read.
    #
    # @param root [String] project root.
    # @param rel [String] path relative to `root`.
    # @return [String, nil]
    def fingerprint(root, rel)
      abs = File.join(File.expand_path(root), rel)
      return "link\0#{File.readlink(abs)}" if File.symlink?(abs)
      return "absent" unless File.exist?(abs)
      return nil unless File.file?(abs)

      # The mode too: git lists a mode change, and a test can depend on it.
      "#{File.stat(abs).mode.to_s(8)}\0#{Digest::SHA256.file(abs).hexdigest}"
    rescue SystemCallError
      nil
    end

    # The commit that is checked out in the work tree of `root`.
    #
    # @param root [String] project root.
    # @return [String, nil] the commit id. Nil when {inside?} is false, when
    #   the work tree has no commit, or when git fails.
    def head(root)
      return nil unless inside?(root)

      out, status = git(root, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
      id = out.to_s.strip
      status&.success? && id.match?(/\A\h{40,64}\z/) ? id : nil
    end

    # True when `root` is in a git work tree and git does not ignore it.
    #
    # @param root [String] project root.
    # @return [Boolean]
    def inside?(root)
      out, status = git(root, "rev-parse", "--is-inside-work-tree")
      return false unless status&.success? && out.strip == "true"

      _out, ignored = git(root, "check-ignore", "--quiet", "--", ".")
      !ignored&.success?
    end

    # True when `commit` is a commit in the clone of `root`.
    #
    # @param commit [String] commit id.
    # @param root [String] project root.
    # @return [Boolean]
    def commit?(commit, root)
      _out, status = git(root, "cat-file", "-e", "#{commit}^{commit}")
      status&.success? == true
    end

    # The paths below `root` that can differ from `commit` now: changed, added
    # or deleted tracked files (staged or not), untracked files that git does
    # not ignore, and every file that git was told not to look at
    # (assume-unchanged or skip-worktree), on disk or not: git reports no edit
    # to such a file, and no removal by a sparse checkout. A changed submodule is its path. An
    # untracked nested repository is its folder, with a trailing slash.
    #
    # @param commit [String] commit id.
    # @param root [String] project root.
    # @return [Array<String>, nil] paths relative to `root`, or nil when git fails.
    def changed_since(commit, root)
      tracked = list(root, "diff", "--name-only", "--no-renames", "--ignore-submodules=none", "--relative", "-z", commit, "--")
      untracked = list(root, "ls-files", "--others", "--exclude-standard", "-z")
      flagged = list(root, "ls-files", "-v", "-z")
      return nil unless tracked && untracked && flagged

      unwatched = flagged.filter_map do |row|
        tag, rel = row.split(" ", 2)
        rel if rel && (tag == "S" || tag.match?(/\A[a-z]\z/))
      end
      (tracked + untracked + unwatched).uniq
    end

    # Runs one git command that prints NUL-separated paths.
    #
    # @param root [String] project root.
    # @param args [Array<String>] git arguments.
    # @return [Array<String>, nil] the paths, or nil when git fails.
    def list(root, *args)
      out, status = git(root, *args)
      return nil unless status&.success?

      out.split("\0").map { |path| FsPath.read(path) }
    end

    # Runs git in `root` without the variables of {GIT_ENV}.
    #
    # @param root [String] project root.
    # @param args [Array<String>] git arguments.
    # @return [Array(String, Process::Status), Array(String, nil)] stdout and
    #   the status, or an empty string and nil when git cannot start.
    def git(root, *args)
      out, _err, status = Open3.capture3(GIT_ENV, "git", "-C", root, *args, binmode: true)
      [out, status]
    rescue SystemCallError
      ["", nil]
    end
  end
end
