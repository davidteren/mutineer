# frozen_string_literal: true

module Mutineer
  class CoverageMap
    # Records the lines that each test file covers, the lines that ran at load,
    # and the files that each capture loaded. Also builds the Ruby text that a
    # child script uses to report them.
    #
    # These are private methods of {Mutineer::CoverageMap}. They read and write
    # its instance variables.
    #
    # @api private
    module Recording
      private

      # Records every source line with a non-zero execution count as covered by
      # this test file. The counts are lines that ran after the sources loaded.
      # Coverage.result keys are absolute; relativize and drop any path outside
      # the project (stdlib/gem files).
      def record(coverage, test_path)
        rel_test = relativize(test_path)
        each_covered_key(coverage) { |key| add_covering_test(key, rel_test) }
      end

      # Adds `rel_test` to the map entry for `key`, in `@test_paths` order.
      # A partial recapture appends a test that a full capture would have
      # recorded earlier. Sorting by the run's test order keeps the two maps
      # equal (#421). A full capture appends in order, so it takes the fast
      # path: sorting on every append made capture quadratic in the test count.
      #
      # @api private
      # @param key [String] a "file:line" map key.
      # @param rel_test [String] project-relative test path.
      # @return [void]
      def add_covering_test(key, rel_test)
        list = (@map[key] ||= [])
        last = list.last
        if last.nil? || test_index(last) < test_index(rel_test)
          list << rel_test
        else
          list << rel_test unless list.include?(rel_test)
          list.sort_by! { |test| test_index(test) }
        end
      end

      # Position of `rel` in `@test_paths`. A path outside the run sorts last.
      #
      # @api private
      # @param rel [String] project-relative test path.
      # @return [Integer]
      def test_index(rel)
        @test_index ||= @test_paths.each_with_index.to_h { |path, index| [relativize(path), index] }
        @test_index.fetch(rel, @test_index.length)
      end

      # Line counts for the map, with `def` lines of methods the test called
      # filled in. A fork capture already did that and sends plain arrays.
      #
      # @api private
      # @param coverage [Hash] counts per absolute file.
      # @return [Hash] the same files, values reduced to line-count arrays.
      def map_coverage(coverage)
        coverage.to_h do |file, data|
          lines = if data.is_a?(Hash) && (data.key?(:methods) || data.key?("methods"))
                    lines_with_called_defs(data)
                  else
                    data
                  end
          [file, lines]
        end
      end

      # Credits `test_path` with source lines that ran only while the sources
      # loaded, when this test is one that should keep them (#426).
      #
      # Standalone capture preloads every source in every test's process, so
      # those lines would otherwise put every `--test` file on the map and a
      # cache hit would check them all. The lines stay in {#load_lines} either
      # way. They stay on the map for a paired test in this run: under
      # `--strategy reload` that test can kill a mutant on the line by checking
      # a value the load built (#348, `Catalog.price`). When the run has no
      # paired test, every test keeps the lines, so that kill is not dropped.
      # A line the test also ran after load is already on the map.
      #
      # @api private
      # @param load_coverage [Hash, nil] the load snapshot from the child.
      # @param test_coverage [Hash] the post-load coverage from the child.
      # @param test_path [String] test file path.
      # @return [void]
      def record_paired_load_lines(load_coverage, test_coverage, test_path)
        return unless load_coverage.is_a?(Hash)

        rel_test = relativize(test_path)
        post = line_counts_by_rel(map_coverage(test_coverage))
        @source_rels ||= @source_paths.to_set { |path| relativize(absolute(path)) }
        load_coverage.each do |abs_file, data|
          rel = relativize(abs_file)
          next unless @source_rels.include?(rel)
          next unless credit_load_only_line?(rel, rel_test)

          counts = data.is_a?(Hash) ? data["lines"] : data
          next unless counts.is_a?(Array)

          post_counts = post[rel]
          counts.each_with_index do |count, idx|
            next unless count&.positive?
            next if post_counts&.[](idx)&.positive?

            add_covering_test("#{rel}:#{idx + 1}", rel_test)
          end
        end
      end

      # Line-count arrays from a coverage hash, keyed by project-relative path.
      #
      # @api private
      # @param coverage [Hash] counts per absolute file.
      # @return [Hash{String => Array}]
      def line_counts_by_rel(coverage)
        coverage.each_with_object({}) do |(abs_file, data), out|
          counts = data.is_a?(Hash) ? (data["lines"] || data[:lines]) : data
          next unless counts.is_a?(Array)

          out[relativize(abs_file)] = counts
        end
      end

      # Whether `rel_test` keeps lines of `rel_source` that ran only at load.
      # A paired test in the run does. When none of the run's tests pair with
      # the source, every test does.
      #
      # @api private
      # @param rel_source [String] project-relative source path.
      # @param rel_test [String] project-relative test path.
      # @return [Boolean]
      def credit_load_only_line?(rel_source, rel_test)
        paired = paired_tests_in_run(rel_source)
        paired.empty? || paired.include?(rel_test)
      end

      # Conventional tests for `rel_source` that this run actually captures.
      #
      # @api private
      # @param rel_source [String] project-relative source path.
      # @return [Array<String>] project-relative test paths.
      def paired_tests_in_run(rel_source)
        @paired_in_run ||= {}
        @paired_in_run[rel_source] ||= begin
          run = @test_paths.to_set { |path| relativize(path) }
          Pairing.infer_tests(rel_source, project_root: @project_root, prefer: @framework || "minitest")
                 .select { |path| run.include?(path) }
        end
      end

      # True when a standalone cache was built with the #426 load-line rule
      # and the same paired tests would keep load-only lines now. Boot and
      # daemon maps never credited those lines to tests.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @return [Boolean]
      def standalone_load_lines_current?(cached)
        return true if @boot_path

        cached[NARROW_LOAD_LINES] == true && load_line_pairs_match?(cached)
      end

      # The tests in this run that {#credit_load_only_line?} treats as paired,
      # per source. An empty list means every test keeps the load-only lines.
      #
      # @api private
      # @return [Hash{String => Array<String>}] project-relative source to sorted test paths.
      def load_line_pairs
        @source_paths.filter_map do |source|
          rel = relativize(absolute(source))
          next if rel.start_with?("/")

          [rel, paired_tests_in_run(rel).sort]
        end.to_h
      end

      # True when `cached` recorded the same {#load_line_pairs} this run has now.
      # A missing key is a map saved before the pairing decision was stored.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @return [Boolean]
      def load_line_pairs_match?(cached)
        saved = cached[LOAD_LINE_PAIRS]
        return false unless saved.is_a?(Hash)

        current = load_line_pairs
        return false unless saved.keys.sort == current.keys.sort

        current.all? { |rel, tests| Array(saved[rel]).sort == tests }
      end

      # Adds the configured source lines that ran at load to {#load_lines}, and
      # the methods called at load to {#load_methods}. Lines of other files
      # (tests, helpers, gems) are dropped.
      #
      # @api private
      # @param coverage [Hash, nil] counts per absolute file, as {#record} reads
      #   them; a Hash entry can also hold "methods", as {#load_entry} builds it.
      # @return [void]
      def record_load(coverage)
        lines, methods = load_sets_from(coverage)
        return if lines.nil?

        @load_lines.merge(lines)
        @load_methods.merge(methods)
        return unless @collect_load

        @seen_load_lines = lines
        @seen_load_methods = methods
      end

      # Line and method keys that ran at load in `coverage`, limited to this
      # run's sources. `[nil, nil]` when `coverage` is not a snapshot.
      #
      # @api private
      # @param coverage [Hash, nil] counts per absolute file, as {#record_load} reads them.
      # @return [Array(Set, Set), Array(nil, nil)]
      def load_sets_from(coverage)
        return [nil, nil] unless coverage.is_a?(Hash)

        lines = Set.new
        methods = Set.new
        ours = coverage.select { |abs_file, _| source_rels.include?(relativize(abs_file)) }
        each_covered_key(ours) { |key| lines << key }
        ours.each do |abs_file, data|
          next unless data.is_a?(Hash) && data["methods"].is_a?(Array)

          data["methods"].each { |line, column| methods << "#{relativize(abs_file)}:#{line}:#{column}" }
        end
        [lines, methods]
      end

      # One file's line counts, with the `def` line of each method the test
      # called counted too (#209). A forked capture does not see the `def` lines
      # run, since the boot defined the methods before the test. Standalone
      # capture clears the load snapshot before the test, so it does not either.
      # Ruby counts no line when an endless method runs, so without this its
      # mutants would be `no_coverage` even when a test calls it. A line where
      # more than one method starts is not counted: the map keys tests by line,
      # so the test would also be credited with the methods it did not call.
      #
      # @api private
      # @param data [Hash] `Coverage` result for one file, with `:lines` and
      #   `:methods`, or the JSON shape from {#test_coverage_assignment}
      #   (`"lines"` and `"methods"` as `[line, column, count]` rows).
      # @return [Array, nil] line counts.
      def lines_with_called_defs(data)
        lines = data[:lines] || data["lines"]
        methods = data[:methods] || data["methods"]
        return lines unless lines && methods

        lines = lines.dup
        entries = method_call_entries(methods)
        starts = entries.map(&:first).tally
        entries.each do |line, count|
          lines[line - 1] = [lines[line - 1].to_i, count].max if count.positive? && starts[line] == 1
        end
        lines
      end

      # Start line and call count for each method in a Coverage method table.
      # A Hash is the live Coverage result. An Array is the JSON shape
      # `[line, column, count]` from {#test_coverage_assignment}.
      #
      # @api private
      # @param methods [Hash, Array] method counts.
      # @return [Array<Array(Integer, Integer)>] `[start_line, count]` pairs.
      def method_call_entries(methods)
        if methods.is_a?(Hash)
          methods.map { |key, count| [key[2], count.to_i] }
        else
          Array(methods).filter_map do |row|
            next unless row.is_a?(Array) && row.size >= 3 && row[0].is_a?(Integer) && row[2].is_a?(Numeric)

            [row[0], row[2].to_i]
          end
        end
      end

      # One file's load-time coverage in the shape {#record_load} reads: the line
      # counts, and the `[line, column]` of each method called at least once.
      # {#load_coverage_expression} builds the same shape in a capture child.
      #
      # @api private
      # @param lines [Array, nil] line counts.
      # @param methods [Hash, nil] `Coverage` method counts, keyed by
      #   `[owner, name, start_line, start_column, end_line, end_column]`.
      # @return [Hash{String => Array}]
      def load_entry(lines, methods)
        { "lines" => lines, "methods" => (methods || {}).filter_map { |key, count| key[2, 2] if count.positive? } }
      end

      # Ruby source of the capture child's load-time coverage: `Coverage.peek_result`
      # for the configured sources only, matched by real path (a Coverage key is
      # the path as required), so the payload does not carry every loaded gem.
      # Each entry has the shape {#load_entry} builds.
      #
      # @api private
      # @return [String] expression to embed in a capture subprocess script.
      def load_coverage_expression
        "Coverage.peek_result.filter_map { |f, v| key = Mutineer::FsPath.read((File.realpath(f) rescue f)); " \
          "[key, { \"lines\" => v[:lines], \"methods\" => v[:methods].filter_map { |k, n| k[2, 2] if n.positive? } }] " \
          "if #{abs_source_paths.map { |path| FsPath.read(path) }.inspect}.include?(key) }.to_h"
      end

      # Ruby that drops the line and method counts recorded while the sources
      # loaded, and leaves Coverage running for the test (#426). The same call
      # the fork capture uses before a test. The load snapshot in `_load` is
      # already a copy, so this does not erase {#load_lines}.
      #
      # @api private
      # @return [String] one statement for a capture subprocess script.
      def discard_load_counts_expression
        "Coverage.result(clear: true, stop: false)"
      end

      # Ruby that stores the test's post-load coverage in `_coverage`.
      # Each file keeps its line counts and every method as
      # `[start_line, start_column, count]`, so {#lines_with_called_defs} can
      # credit a `def` line the test called. A line that ran only while the
      # sources loaded is absent, because {#discard_load_counts_expression} ran
      # first. Coverage keys are US-ASCII with invalid bytes under LC_ALL=C,
      # so each key is read back with {FsPath.read} (#346).
      #
      # @api private
      # @return [String] statements for a capture subprocess script.
      def test_coverage_assignment
        <<~RUBY.chomp
          _raw = Coverage.result
          _coverage = _raw.to_h do |_f, _v|
            next [Mutineer::FsPath.read(_f), _v] unless _v.is_a?(Hash)

            [Mutineer::FsPath.read(_f),
             { "lines" => _v[:lines], "methods" => (_v[:methods] || {}).map { |_k, _n| [_k[2], _k[3], _n] } }]
          end
        RUBY
      end

      # Yields a "file:line" key for every project line with a non-zero count.
      #
      # @api private
      # @param coverage [Hash] counts per absolute file: an Array, or a Hash with "lines".
      # @yieldparam key [String] the "file:line" key.
      # @return [void]
      def each_covered_key(coverage)
        coverage.each do |abs_file, data|
          rel = relativize(abs_file)
          next if rel.start_with?("/") # outside project_root: not our source

          counts = data.is_a?(Hash) ? data["lines"] : data
          next unless counts.is_a?(Array) # a Coverage mode without line counts

          counts.each_with_index { |count, idx| yield "#{rel}:#{idx + 1}" if count&.positive? }
        end
      end

      # Ruby source of the child-side `$LOADED_FEATURES` filter (project `.rb` files).
      #
      # @api private
      # @return [String] expression to embed in a capture subprocess script.
      def loaded_files_expression
        root = FsPath.read(project_root_real)
        prefix = root.b
        prefix += "/".b unless prefix.end_with?("/".b)
        # Byte prefix: a UTF-8 root and a binary loaded path must not raise.
        # A raise here used to be rescued into an empty list, and an empty
        # dependency hash then matched a stale cache (#346).
        "begin; _root = #{prefix.inspect}; $LOADED_FEATURES.filter_map { |f| next unless f.b.end_with?(\".rb\".b); abs = (File.realpath(f) rescue next); Mutineer::FsPath.read(abs) if Mutineer::FsPath.bytes_start_with?(abs, _root) }; rescue StandardError; []; end"
      end

      # Canonical project root for loaded-feature matching (`/var` vs `/private/var`).
      #
      # @api private
      # @return [String] realpath of the project root when it exists.
      def project_root_real = ProjectPath.root_real(@project_root)

      # Project-local `.rb` files loaded in this process at capture time.
      #
      # @api private
      # @return [Array<String>] absolute realpaths.
      def capture_loaded_files
        root = FsPath.read(project_root_real)
        prefix = root.b
        prefix += "/".b unless prefix.end_with?("/".b)
        $LOADED_FEATURES.filter_map do |f|
          next unless f.b.end_with?(".rb".b)

          abs = File.realpath(f)
          FsPath.read(abs) if FsPath.bytes_start_with?(abs, prefix)
        rescue Errno::ENOENT
          nil
        end
      end

      # Fingerprints project-local support files from a capture payload.
      #
      # @api private
      # @param paths [Array, nil] absolute loaded-file paths.
      # @return [void]
      def record_loaded(paths)
        Array(paths).each do |raw|
          next unless raw.is_a?(String) && File.file?(raw)

          abs = File.realpath(raw)
          rel = loaded_relative(abs)
          next unless rel
          next unless rel.end_with?(".rb")
          next if rel.start_with?("vendor/bundle/") || rel.start_with?("node_modules/")

          @loaded_dependencies[rel] = file_fingerprint(abs)
        end
      end

      # Path of `abs` relative to the real project root, or nil when outside it.
      #
      # @api private
      # @param abs [String] absolute realpath.
      # @return [String, nil]
      def loaded_relative(abs)
        root = FsPath.read(project_root_real)
        prefix = root.b
        prefix += "/".b unless prefix.end_with?("/".b)
        return unless FsPath.bytes_start_with?(abs, prefix)

        FsPath.bytes_delete_prefix(abs, prefix)
      end
    end
  end
end
