# frozen_string_literal: true

require_relative "project_path"

module Mutineer
  # Source -> test pairing by path convention (#11). Pure stdlib path logic:
  # no Rails, no class loading, no process. Six jobs:
  #   * expand_sources — a directory argument becomes its sorted **/*.rb files;
  #                     a file inside the root becomes its root-relative path.
  #   * expand_test: one --test value (#380). A directory becomes the test
  #                     files under it. A glob becomes the files it matches.
  #                     An existing file stays as typed.
  #   * resolve_test_map — expand each `tests:` map entry's source and test
  #                     patterns (#382), clean and dedupe the file lists, and
  #                     record every pattern that matched no file.
  #   * mapped_tests_for — the mapped tests for one source from a resolved
  #                     map, concatenated in entry order (#382).
  #   * infer_tests    — a source's test files by convention (app/ and lib/
  #                     sources map to test/.../_test.rb, test/.../<name>_*_test.rb,
  #                     test/.../test_*.rb or spec/.../_spec.rb), preserving
  #                     namespaced subdirectories. The first EXISTING exact
  #                     candidate stays first. Split Minitest files join a
  #                     Minitest match. A matched spec is left as that one file.
  #                     A concern at app/<dir>/concerns/<rest>.rb with no test
  #                     there also tries exact names at <dir>/<rest>.
  #   * test_given_as_source? — whether a positional argument is a test file
  #                     by these same names, given as a source by mistake
  #                     after `--test` (#293).
  #
  # Independently unit-testable: every method is pure in/out over the
  # filesystem, so the pairing contract is exercised with plain fixtures, no
  # Rails, no fork.
  module Pairing
    module_function

    # Expand each positional source: a directory -> its sorted **/*.rb files
    # (relative to project_root); a file (or glob, or anything non-directory)
    # -> its path relative to project_root, so `./lib/x.rb` and an absolute
    # path pair like `lib/x.rb` (#104). A missing file, or one outside the
    # root, stays as typed. Flattened, deduped, order-stable.
    #
    # @param args [Array<String>] source paths or directories.
    # @param project_root [String] repository root for relative expansion.
    # @return [Array<String>] flattened, deduped source file list.
    def expand_sources(args, project_root:)
      root = FsPath.read(File.expand_path(project_root))
      # The root as typed and as its real path (macOS `/var` vs `/private/var`),
      # resolved once for every file below.
      roots = [root, ProjectPath.root_real(root)].uniq
      Array(args).flat_map do |arg|
        arg = FsPath.read(arg)
        abs = File.expand_path(arg, root)
        if File.directory?(abs)
          # Escape metacharacters in the directory name so `component[1]` stays
          # literal (same rule as {directory_test_files}).
          listed = if (rel = root_relative(abs, roots))
                     fs_glob(File.join(glob_literal(rel), "**", "*.rb"), base: root)
                   else
                     fs_glob(File.join(glob_literal(abs), "**", "*.rb"))
                   end
          listed.sort.map do |f|
            full = File.absolute_path?(f) ? f : File.expand_path(f, root)
            existing_relative(full, roots) || full
          end
        else
          # `..` resolves as text, as FileSwap and the daemon already read it.
          [(existing_relative(abs, roots) if File.exist?(abs)) || arg]
        end
      end.map { |path| FsPath.read(path) }.uniq
    end

    # Characters that make a --test value a glob when no path has that name.
    # An existing file is never read as a glob, so a name may contain these.
    TEST_GLOB_MARK = /[*?\[{]/

    # How one --test value is read. Blank is not a directory: File.expand_path
    # of "" is the project root, and that would select every test.
    #
    # @param value [String] one --test value, as typed.
    # @param project_root [String] repository root.
    # @return [Symbol] :blank, :directory, :file, :glob, or :plain.
    def classify_test_value(value, project_root:)
      return :blank if value.nil? || value.strip.empty?

      abs = File.expand_path(value, project_root)
      return :directory if File.directory?(abs)
      return :file if File.exist?(abs)
      return :glob if value.match?(TEST_GLOB_MARK)

      :plain
    end

    # One --test value, as paths. [] means a directory or glob matched nothing.
    # A file stays as typed. A missing plain path stays as typed, so the CLI
    # can still say "no such file". Paths from a directory or glob are sorted.
    # Inside the project they are root-relative. Outside it they are absolute.
    #
    # @param value [String] one --test value, as typed.
    # @param project_root [String] repository root.
    # @return [Array<String>] matching paths, or [value] when it is not expanded.
    def expand_test(value, project_root:)
      root = File.expand_path(project_root)
      roots = [root, ProjectPath.root_real(root)].uniq
      case classify_test_value(value, project_root: project_root)
      when :directory
        directory_test_files(File.expand_path(value, root), root, roots)
      when :glob
        glob_test_files(value, root, roots)
      else
        [value]
      end
    end

    # Expand every entry of a checked `test_map` into cleaned file lists.
    # Source patterns use Dir.glob then {expand_sources}, so a directory
    # match becomes its `.rb` files and `./lib/a.rb` / `lib//a.rb` clean to
    # the same path. Test patterns go through {expand_test}; a missing plain
    # path is dropped (no match). Overlapping patterns keep each file once,
    # sorted. Patterns with no file are listed under `:unmatched` with a
    # 1-based entry number and the key (`"sources"` or `"tests"`). Does not
    # print or exit; the CLI reports unmatched patterns (#382).
    #
    # @param test_map [Array<Hash{Symbol => Array<String>}>] checked map entries
    #   with `:sources` and `:tests` pattern lists.
    # @param project_root [String] repository root for relative expansion.
    # @return [Hash{Symbol => Array}] `:entries` is
    #   `[{sources: [...], tests: [...]}, ...]`; `:unmatched` is
    #   `[{entry: Integer, key: String, pattern: String}, ...]`.
    def resolve_test_map(test_map, project_root:)
      root = File.expand_path(project_root)
      roots = [root, ProjectPath.root_real(root)].uniq
      unmatched = []
      entries = Array(test_map).each_with_index.map do |entry, index|
        number = index + 1
        sources = expand_map_patterns(Array(entry[:sources]), number, "sources", unmatched) do |pattern|
          expand_map_source_pattern(pattern, root, roots)
        end
        tests = expand_map_patterns(Array(entry[:tests]), number, "tests", unmatched) do |pattern|
          expand_map_test_pattern(pattern, root, roots)
        end
        { sources: sources, tests: tests }
      end
      { entries: entries, unmatched: unmatched }
    end

    # Mapped test files for one source from a resolved map. Each entry whose
    # expanded sources include `source` contributes its tests, in entry order.
    # An unmatched source returns `[]`. Does not dedupe across entries; the
    # CLI unions the run's test list (#382).
    #
    # @param source [String] root-relative source path, as in the resolved map.
    # @param resolved [Hash{Symbol => Array}] result of {resolve_test_map}.
    # @return [Array<String>] mapped test paths in entry order.
    def mapped_tests_for(source, resolved)
      Array(resolved[:entries]).each_with_object([]) do |entry, out|
        out.concat(entry[:tests]) if entry[:sources].include?(source)
      end
    end

    # Characters Dir.glob reads as a pattern. A real directory name may
    # contain them. They are escaped so the name stays a literal prefix.
    GLOB_META = /([*?\[\]{}\\])/

    # A path used as a literal prefix in Dir.glob.
    #
    # @param path [String] directory path, relative or absolute.
    # @return [String] the same path with pattern characters escaped.
    def glob_literal(path)
      FsPath.read(path).gsub(GLOB_META) { "\\#{Regexp.last_match(1)}" }
    end

    # `Dir.glob` with each path read as UTF-8, or binary when it is not (#346).
    #
    # @param args [Array] arguments forwarded to {Dir.glob}.
    # @return [Array<String>]
    def fs_glob(*args, **kwargs)
      Dir.glob(*args, **kwargs).map { |path| FsPath.read(path) }
    end

    # `Dir.children` with each name read as UTF-8, or binary when it is not (#346).
    #
    # @param dir [String] directory to list.
    # @return [Array<String>]
    def fs_children(dir)
      Dir.children(dir).map { |path| FsPath.read(path) }
    end

    # Test files under a directory. The name rule is {TEST_NAME}. Dot entries
    # stay out, because Dir.glob skips them. The result is sorted.
    # The directory name is literal, even when it contains a pattern character.
    #
    # @param abs [String] absolute directory path.
    # @param root [String] expanded project root.
    # @param roots [Array<String>] the project root, expanded and real.
    # @return [Array<String>] root-relative paths, or absolute paths outside the root.
    def directory_test_files(abs, root, roots)
      listed = if (rel = root_relative(abs, roots))
                 fs_glob(File.join(glob_literal(rel), "**", "*.rb"), base: root)
               else
                 fs_glob(File.join(glob_literal(abs), "**", "*.rb"))
               end
      listed.filter_map { |match| named_test_file(match, root, roots) }.sort
    end

    # Files a glob matches from the project root. Directories are ignored.
    # There is no test-name filter. An absolute pattern ignores base.
    # Dir.glob keeps a leading "./"; the path is then made root-relative.
    #
    # @param pattern [String] glob as typed.
    # @param root [String] expanded project root.
    # @param roots [Array<String>] the project root, expanded and real.
    # @return [Array<String>] sorted matching file paths.
    def glob_test_files(pattern, root, roots)
      listed = if File.absolute_path?(pattern)
                 fs_glob(pattern)
               else
                 fs_glob(pattern, base: root)
               end
      listed.filter_map { |match| glob_file(match, root, roots) }.sort
    end

    # A directory match whose basename is a test name, as a stored path.
    #
    # @param match [String] path from Dir.glob.
    # @param root [String] expanded project root.
    # @param roots [Array<String>] the project root, expanded and real.
    # @return [String, nil] stored path, or nil when the match is not a test file.
    def named_test_file(match, root, roots)
      full = File.absolute_path?(match) ? match : File.expand_path(match, root)
      return unless File.file?(full)
      return unless File.basename(full).match?(TEST_NAME)

      existing_relative(full, roots) || full
    end

    # A glob match that is a file, as a stored path. Directories are dropped.
    #
    # @param match [String] path from Dir.glob.
    # @param root [String] expanded project root.
    # @param roots [Array<String>] the project root, expanded and real.
    # @return [String, nil] stored path, or nil when the match is not a file.
    def glob_file(match, root, roots)
      full = File.absolute_path?(match) ? match : File.expand_path(match, root)
      return unless File.file?(full)

      existing_relative(full, roots) || full
    end

    # Expand each pattern for one map key. An empty expansion records the
    # pattern under `unmatched`. Results are deduped and sorted.
    #
    # @api private
    # @param patterns [Array<String>] source or test patterns from one entry.
    # @param number [Integer] 1-based entry index.
    # @param key [String] `"sources"` or `"tests"`.
    # @param unmatched [Array<Hash>] accumulator for patterns with no file.
    # @yieldparam pattern [String] one pattern to expand.
    # @yieldreturn [Array<String>] matching file paths.
    # @return [Array<String>] cleaned, deduped, sorted paths.
    def expand_map_patterns(patterns, number, key, unmatched)
      patterns.flat_map do |pattern|
        files = yield(pattern)
        unmatched << { entry: number, key: key, pattern: pattern } if files.empty?
        files
      end.uniq.sort
    end

    # One map source pattern: Dir.glob then {expand_sources}, so a matched
    # directory becomes its `.rb` files and path spellings clean the same way.
    # Matches outside the project root are dropped (brace patterns like
    # `{..,app}/x.rb` can escape a text-only `..` check).
    #
    # @api private
    # @param pattern [String] relative source pattern.
    # @param root [String] expanded project root.
    # @param roots [Array<String>] the project root, expanded and real.
    # @return [Array<String>] matching source paths, sorted.
    def expand_map_source_pattern(pattern, root, roots)
      # An existing file or directory is literal, even when its name holds a
      # glob character (same rule as {classify_test_value} for --test).
      abs = File.expand_path(pattern, root)
      listed = if File.exist?(abs)
                 [pattern]
               else
                 fs_glob(pattern, base: root)
               end
      return [] if listed.empty?

      expand_sources(listed, project_root: root).filter_map do |path|
        path_abs = File.expand_path(path, root)
        next unless File.exist?(path_abs)

        existing_relative(path_abs, roots)
      end.uniq.sort
    end

    # One map test pattern. Directories (typed or matched by a glob) expand
    # with the {TEST_NAME} filter, matching a typed `--test` directory. Files
    # a glob matches stay unfiltered (including `test_helper.rb`), matching
    # `--test` globs. A missing plain path is not a match. Matches outside the
    # project root are dropped (#382 review).
    #
    # @api private
    # @param pattern [String] relative test pattern.
    # @param root [String] expanded project root.
    # @param roots [Array<String>] the project root, expanded and real.
    # @return [Array<String>] matching test paths, sorted.
    def expand_map_test_pattern(pattern, root, roots)
      listed = case classify_test_value(pattern, project_root: root)
               when :directory
                 directory_test_files(File.expand_path(pattern, root), root, roots)
               when :glob
                 expand_map_test_glob(pattern, root, roots)
               else
                 # :file / :plain / :blank — same as {expand_test}, then root-filter.
                 expand_test(pattern, project_root: root)
               end
      listed.filter_map do |path|
        abs = File.expand_path(path, root)
        next unless File.file?(abs)

        existing_relative(abs, roots)
      end.uniq.sort
    end

    # Glob matches for a map `tests:` pattern. A matched directory expands with
    # {directory_test_files}; a matched file is kept as-is (no name filter).
    # `--test` globs still drop directories; only the map expands them (#382).
    #
    # @api private
    # @param pattern [String] relative or absolute glob.
    # @param root [String] expanded project root.
    # @param roots [Array<String>] the project root, expanded and real.
    # @return [Array<String>] matching test paths (may include outside-root paths).
    def expand_map_test_glob(pattern, root, roots)
      matches = if File.absolute_path?(pattern)
                  fs_glob(pattern)
                else
                  fs_glob(pattern, base: root)
                end
      matches.flat_map do |match|
        full = File.absolute_path?(match) ? match : File.expand_path(match, root)
        if File.directory?(full)
          directory_test_files(full, root, roots)
        elsif File.file?(full)
          [existing_relative(full, roots) || full]
        else
          []
        end
      end
    end

    # An existing file's root-relative path, or nil outside the root. Tries the
    # path as given, then with its directory resolved, so a path typed through
    # a symlinked parent (or macOS `/var` under a `/private/var` root) matches.
    # The file's own name is kept, so a symlinked file is not renamed.
    #
    # @param abs [String] expanded absolute path of an existing file.
    # @param roots [Array<String>] the project root, expanded and real.
    # @return [String, nil] root-relative path, or nil outside the root.
    def existing_relative(abs, roots)
      root_relative(abs, roots) ||
        root_relative(File.join(File.realpath(File.dirname(abs)), File.basename(abs)), roots)
    end

    # `abs` relative to the first of `roots` it is under, or nil. Text only: a
    # symlinked source keeps its own name (realpath would rename it to its
    # target and pair the wrong test). `roots` holds the root's real path too,
    # so the macOS `/var` vs `/private/var` alias still matches.
    #
    # @param abs [String] expanded absolute path.
    # @param roots [Array<String>] the project root, expanded and real.
    # @return [String, nil] root-relative path, or nil outside the root.
    def root_relative(abs, roots)
      abs = FsPath.read(abs)
      roots.each do |r|
        r = FsPath.read(r)
        prefix = r.b
        prefix += "/".b unless prefix.end_with?("/".b)
        next unless FsPath.bytes_start_with?(abs, prefix)

        return FsPath.bytes_delete_prefix(abs, prefix)
      end
      nil
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
    # and do not replace it. When that list is empty, a concern tries exact
    # names at its namespace path. Split names stay at the concerns path.
    # Issue #408 tracks namespace split names.
    #
    # @param source_rel [String] relative source path.
    # @param project_root [String] repository root for existence checks.
    # @param prefer [String] preferred framework name.
    # @return [Array<String>] existing test paths, exact candidate first.
    def infer_tests(source_rel, project_root:, prefer: "minitest")
      base, lib = logical_path(source_rel)
      root = File.expand_path(project_root)
      exact = candidates(base, lib, prefer).find { |rel| File.exist?(File.expand_path(rel, root)) }
      found = if exact&.end_with?("_spec.rb")
                [exact]
              else
                ([exact] + split_test_files(base, lib, root)).compact.uniq
              end
      return found unless found.empty?

      ns = namespace_base(source_rel)
      return found unless ns

      pick = candidates(ns, false, prefer).find { |rel| File.exist?(File.expand_path(rel, root)) }
      pick ? [pick] : []
    end

    # Namespace mirror for a concern, or nil.
    # `app/<dir>/concerns/<rest>.rb` returns `<dir>/<rest>`.
    # `concerns` must sit directly under `app/<dir>`.
    #
    # @param source_rel [String] relative source path.
    # @return [String, nil] logical base without extension, or nil.
    def namespace_base(source_rel)
      match = source_rel.match(%r{\Aapp/([^/]+)/concerns/(.+)\.rb\z})
      return unless match

      "#{match[1]}/#{match[2]}"
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

    # Basenames that pair as tests in {candidates}: `*_test.rb`, `*_spec.rb`
    # and Minitest's `test_*.rb`, but not its `test_helper.rb` support file.
    TEST_NAME = /\A(?!test_helper\.rb\z)(?:.+_(?:test|spec)|test_.+)\.rb\z/

    # Whether the `run` guard rejects a positional argument as a test file
    # given as a source (#293). Segments are read from the path relative to
    # the root, so a `test/` folder above the project never counts. A
    # `*_test.rb` / `*_spec.rb` path is flagged when it has a `test/` or
    # `spec/` segment (the guard's original rule), or when it sits in the same
    # directory as a given test, which catches root-level tests. A
    # `test_*.rb` path is flagged only under the
    # project's top-level `test/` or `spec/`, because real sources use the
    # prefix (`lib/mutineer/test_runners.rb`, `lib/foo/test/test_app.rb`). A
    # source whose own test (`<stem>_test.rb`, `test_<stem>.rb`,
    # `<stem>_spec.rb`, or a split `<stem>_*_test.rb` not claimed by a longer
    # source on disk) sits beside it in the test set is not flagged. Paths
    # compare relative to the root, as in
    # {expand_sources} (the root's real path counts too, for macOS `/var` vs
    # `/private/var`), so `./a_test.rb` and `a_test.rb` match. No file content
    # is read.
    #
    # @param path [String] positional argument as typed.
    # @param project_root [String] repository root for relative expansion.
    # @param tests [Array<String>] the explicit test files.
    # @return [Boolean] true when the argument looks like a misplaced test.
    def test_given_as_source?(path, project_root:, tests:)
      name = File.basename(path)
      return false unless name.match?(TEST_NAME)

      root = File.expand_path(project_root)
      roots = [root, ProjectPath.root_real(root)].uniq
      relative = lambda do |p|
        abs = File.expand_path(p, root)
        root_relative(abs, roots) || abs
      end
      rel = relative.call(path)
      # Outside the root, read segments from a relative path as typed
      # (`../test/b_test.rb`) and not from an absolute one, so a `test/`
      # folder above the root never counts.
      segments = root_relative(File.expand_path(path, root), roots)
      segments ||= path.start_with?(File::SEPARATOR) ? "" : path
      return segments.match?(%r{\A(test|spec)/}) unless name.match?(/_(test|spec)\.rb\z/)
      return true if segments.match?(%r{(\A|/)(test|spec)/})

      dir = File.dirname(rel)
      beside = Array(tests).map(&relative)
                           .select { |t| File.dirname(t) == dir }
                           .map { |t| File.basename(t) }
      stem = File.basename(name, ".rb")
      own = ["test_#{stem}.rb", "#{stem}_spec.rb"]
      base = rel.delete_suffix(".rb")
      return false if beside.any? do |t|
        own.include?(t) || (longer_owns_entry?(t, stem) && !claimed_by_longer_source?(root, base, t))
      end

      beside.any?
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
      dirs.flat_map { |dir| split_tests_in(root, dir, name, base) }
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
    # @param base [String] logical source path without extension.
    # @return [Array<String>] sorted relative paths.
    def split_tests_in(root, dir_rel, name, base)
      root_abs = File.expand_path(root)
      dir_abs = File.expand_path(dir_rel, root_abs)
      return [] unless inside_project?(dir_abs, root_abs)
      return [] unless File.directory?(dir_abs)

      fs_children(dir_abs).filter_map do |entry|
        next unless split_entry?(entry, name)
        next unless File.file?(dir_abs.b + "/".b + entry.b)
        next if claimed_by_longer_source?(root, base, entry, dir_rel)

        FsPath.read(dir_rel == "." ? entry.b : dir_rel.b + "/".b + entry.b)
      end.sort
    end

    # True when `dir_abs` is the project root or a directory inside it.
    # A source path such as `../../evil.rb` must not list tests outside the project.
    #
    # @param dir_abs [String] expanded directory.
    # @param root_abs [String] expanded project root.
    # @return [Boolean]
    def inside_project?(dir_abs, root_abs)
      dir_b = FsPath.read(dir_abs).b
      root_b = FsPath.read(root_abs).b
      return true if dir_b == root_b

      prefix = root_b == "/".b ? "/".b : root_b + "/".b
      FsPath.bytes_start_with?(dir_b, prefix)
    end

    # True when `entry` is `<name>_<piece>_test.rb` and not the exact
    # `<name>_test.rb` file.
    #
    # @param entry [String] test file basename.
    # @param name [String] source basename without extension.
    # @return [Boolean]
    def split_entry?(entry, name)
      entry = FsPath.read(entry)
      name = FsPath.read(name)
      return false unless entry.b.end_with?("_test.rb".b)

      needle = name.b + "_".b
      return false unless entry.b.start_with?(needle)

      rest = FsPath.read(entry.b.byteslice(needle.bytesize..).b)
      rest.match?(/\A.+_test\.rb\z/)
    end

    # True when a longer source file on disk owns this split test. `user.rb`
    # does not take `user_session_test.rb` when `user_session.rb` exists in the
    # same directory, under `app/`, or under `lib/`. An intermediate file
    # counts: `bar_upsert.rb` owns `bar_upsert_guards_test.rb`, so `bar.rb`
    # does not.
    #
    # @param root [String] expanded project root.
    # @param base [String] logical source path without extension.
    # @param entry [String] test file basename.
    # @param scanned_dir [String, nil] relative test directory being scanned.
    #   When set, a longer source claims the file only if that source searches
    #   this directory. An `app/` source does not take a `test/lib/` file.
    # @return [Boolean]
    def claimed_by_longer_source?(root, base, entry, scanned_dir = nil)
      name = File.basename(base).b
      stem = entry.b.sub(/_test\.rb\z/, "")
      needle = name + "_".b
      return false unless stem.start_with?(needle)

      rest = stem.byteslice(needle.bytesize..)
      return false if rest.nil? || rest.empty?

      dir = File.dirname(base)
      parts = rest.split("_", -1)
      (1..parts.length).any? do |i|
        longer = name + "_".b + parts.first(i).join("_".b)
        next false unless longer_owns_entry?(entry, longer)

        longer_source_exists?(root, dir, longer, scanned_dir)
      end
    end

    # True when `entry` is the exact test, or a split test with a non-empty
    # piece, for `stem`. `user_session__test.rb` is neither for
    # `user_session`, so that source does not take it from `user.rb`.
    #
    # @param entry [String] test file basename.
    # @param stem [String] longer source basename without extension.
    # @return [Boolean]
    def longer_owns_entry?(entry, stem)
      entry.b == stem.b + "_test.rb".b || split_entry?(entry, stem)
    end

    # True when a longer source file exists beside this logical path.
    # The logical directory itself is checked, so `src/user_session.rb` owns
    # `test/src/user_session_test.rb`. `app/` and `lib/` are checked too, so an
    # `app/` source still yields the name to a `lib/` sibling and the reverse.
    #
    # @param root [String] expanded project root.
    # @param dir [String] logical directory, or `.` when the source has none.
    # @param stem [String] longer source basename without extension.
    # @param scanned_dir [String, nil] relative test directory being scanned.
    # @return [Boolean]
    def longer_source_exists?(root, dir, stem, scanned_dir = nil)
      file = stem.b + ".rb".b
      folders = [dir == "." ? nil : dir]
      %w[app lib].each { |prefix| folders << (dir == "." ? prefix : File.join(prefix, dir)) }
      folders.uniq.any? do |folder|
        rel = folder ? folder.b + "/".b + file : file
        next false unless File.file?(root.b + "/".b + rel)
        next false if scanned_dir && !source_searches_dir?(rel, scanned_dir)

        true
      end
    end

    # True when pairing this source looks in `scanned_dir`.
    #
    # @param source_rel [String] project-relative source path.
    # @param scanned_dir [String] relative test directory.
    # @return [Boolean]
    def source_searches_dir?(source_rel, scanned_dir)
      base, lib = logical_path(source_rel)
      dirs = [mirror_dir("test", base)]
      dirs << mirror_dir("test/lib", base) if lib
      dirs.include?(scanned_dir)
    end
  end
end
