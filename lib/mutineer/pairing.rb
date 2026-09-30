# frozen_string_literal: true

module Mutineer
  # Source -> test pairing by path convention (#11). Pure stdlib path logic:
  # no Rails, no class loading, no process. Two jobs:
  #   * expand_sources — a directory argument becomes its sorted **/*.rb files.
  #   * infer_tests    — a source's test files by convention (app/ and lib/
  #                     sources map to test/.../_test.rb, test/.../<name>_*_test.rb,
  #                     test/.../test_*.rb or spec/.../_spec.rb), preserving
  #                     namespaced subdirectories. The first EXISTING exact
  #                     candidate stays first. Split Minitest files join a
  #                     Minitest match. A matched spec is left as that one file.
  #
  # Independently unit-testable: every method is pure in/out over the
  # filesystem, so the pairing contract is exercised with plain fixtures, no
  # Rails, no fork.
  module Pairing
    module_function

    # Expand each positional source: a directory -> its sorted **/*.rb files
    # (relative to project_root); a file (or glob, or anything non-directory)
    # -> itself. Flattened, deduped, order-stable.
    #
    # @param args [Array<String>] source paths or directories.
    # @param project_root [String] repository root for relative expansion.
    # @return [Array<String>] flattened, deduped source file list.
    def expand_sources(args, project_root:)
      root = File.expand_path(project_root)
      Array(args).flat_map do |arg|
        abs = File.expand_path(arg, root)
        if File.directory?(abs)
          Dir.glob(File.join(abs, "**", "*.rb")).sort.map { |f| f.delete_prefix("#{root}/") }
        else
          [arg]
        end
      end.uniq
    end

    # The first test path {#infer_tests} would run for a source, or nil.
    # `prefer` is the resolved framework ("minitest" | "rspec"): its candidates
    # are tried first, the other framework's as fallback, so a minitest default
    # still finds a spec and vice-versa.
    #
    # @param source_rel [String] relative source path.
    # @param project_root [String] repository root for existence checks.
    # @param prefer [String] preferred framework name.
    # @return [String, nil] existing test path or nil.
    def infer_test(source_rel, project_root:, prefer: "minitest")
      infer_tests(source_rel, project_root: project_root, prefer: prefer).first
    end

    # Every test file convention pairs with a source. The first existing exact
    # candidate from {#candidates} stays first. Each `<basename>_*_test.rb` in
    # the mirrored test directory is added after it (#87). A spec that the exact
    # rules already found is left alone: split Minitest names do not join it
    # and do not replace it.
    #
    # @param source_rel [String] relative source path.
    # @param project_root [String] repository root for existence checks.
    # @param prefer [String] preferred framework name.
    # @return [Array<String>] existing test paths, exact candidate first.
    def infer_tests(source_rel, project_root:, prefer: "minitest")
      base, lib = logical_path(source_rel)
      root = File.expand_path(project_root)
      exact = candidates(base, lib, prefer).find { |rel| File.exist?(File.expand_path(rel, root)) }
      return [exact] if exact&.end_with?("_spec.rb")

      ([exact] + split_test_files(base, lib, root)).compact.uniq
    end

    # Strip the source root to a logical path (no ".rb") and flag lib/
    # sources. app/foo/bar.rb and lib/foo/bar.rb both -> "foo/bar"; anything
    # else -> the path minus ".rb" (still attempted). Namespaced subdirs are
    # preserved verbatim — structural, never constant resolution.
    #
    # @param source_rel [String] relative source path.
    # @return [Array(String, Boolean)] logical base path and whether it came from lib/.
    def logical_path(source_rel)
      no_ext = source_rel.sub(/\.rb\z/, "")
      if no_ext.start_with?("app/")
        [no_ext.sub(%r{\Aapp/}, ""), false]
      elsif no_ext.start_with?("lib/")
        [no_ext.sub(%r{\Alib/}, ""), true]
      else
        [no_ext, false]
      end
    end

    # Ordered candidate test paths: _test.rb, then Minitest's test_*.rb, then
    # _spec.rb. lib/ sources also get the test/lib/... and spec/lib/... layouts.
    #
    # @param base [String] logical source path without extension.
    # @param lib [Boolean] whether the source originated from lib/.
    # @param prefer [String] preferred framework name.
    # @return [Array<String>] candidate test paths in preferred order.
    def candidates(base, lib, prefer)
      minitest = ["test/#{base}_test.rb"]
      minitest << "test/lib/#{base}_test.rb" if lib
      unless File.basename(base) == "helper" # test/test_helper.rb is Minitest's support file, not a test
        prefixed = base.sub(%r{[^/]+\z}) { |name| "test_#{name}" }
        minitest << "test/#{prefixed}.rb"
        minitest << "test/lib/#{prefixed}.rb" if lib
      end
      rspec = ["spec/#{base}_spec.rb"]
      rspec << "spec/lib/#{base}_spec.rb" if lib
      prefer == "rspec" ? rspec + minitest : minitest + rspec
    end

    # `<basename>_*_test.rb` files in each mirrored test directory (#87). The
    # exact `<basename>_test.rb` name is not included. `lib/` sources also look
    # under `test/lib/`. Names are matched as text, not as a glob, so a basename
    # that contains `*` stays literal. `test/` comes before `test/lib/`, and
    # each directory is sorted.
    #
    # @param base [String] logical source path without extension.
    # @param lib [Boolean] whether the source originated from lib/.
    # @param root [String] expanded project root.
    # @return [Array<String>] relative split-test paths.
    def split_test_files(base, lib, root)
      name = File.basename(base)
      dirs = [mirror_dir("test", base)]
      dirs << mirror_dir("test/lib", base) if lib
      dirs.flat_map { |dir| split_tests_in(root, dir, name) }
    end

    # Relative test directory for a logical source path. A source with no
    # subdirectory (`calc`) maps to `prefix` itself, not `prefix/.`.
    #
    # @param prefix [String] `test` or `test/lib`.
    # @param base [String] logical source path without extension.
    # @return [String] relative directory.
    def mirror_dir(prefix, base)
      dir = File.dirname(base)
      dir == "." ? prefix : File.join(prefix, dir)
    end

    # Split test files directly inside `dir_rel` (not in subdirectories).
    #
    # @param root [String] expanded project root.
    # @param dir_rel [String] relative directory.
    # @param name [String] source basename without extension.
    # @return [Array<String>] sorted relative paths.
    def split_tests_in(root, dir_rel, name)
      dir_abs = File.join(root, dir_rel)
      return [] unless File.directory?(dir_abs)

      prefix = "#{name}_"
      Dir.children(dir_abs).filter_map do |entry|
        path = File.join(dir_abs, entry)
        next unless File.file?(path)
        next unless entry.end_with?("_test.rb")

        rest = entry.delete_prefix(prefix)
        next if rest == entry
        next unless rest.match?(/\A.+_test\.rb\z/)

        File.join(dir_rel, entry)
      end.sort
    end
  end
end
