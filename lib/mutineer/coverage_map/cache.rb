# frozen_string_literal: true

module Mutineer
  class CoverageMap
    # Checks if the cached map is still current, and applies a full cache hit
    # or a partial recapture of the tests that a changed source affects.
    #
    # These are private methods of {Mutineer::CoverageMap}. They read and write
    # its instance variables.
    #
    # @api private
    module Cache
      private

      # Byte fingerprint of a file for cache dependency checks.
      #
      # @api private
      # @param abs [String] absolute path.
      # @return [String] hex digest.
      def file_fingerprint(abs)
        content = File.binread(abs)
        Digest::SHA256.hexdigest("#{content.bytesize}\0#{content}")
      end

      # True when the cached map recorded support-file fingerprints and they still
      # match. Missing validity data is a miss (rebuild).
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @param except [Array<String>] project-relative paths whose fingerprint
      #   may differ. A method-body edit of a run source is checked by the
      #   skeleton instead (#421). Any other loaded file still has to match.
      # @return [Boolean]
      def dependencies_match?(cached, except: [])
        deps = cached["dependencies"]
        return false unless deps.is_a?(Hash)

        skip = except.to_set
        deps.all? do |rel, fingerprint|
          next true if skip.include?(rel)

          abs = absolute(rel)
          File.file?(abs) && file_fingerprint(abs) == fingerprint
        end
      end

      # True when `cached` is a complete map for this exact run: same digest,
      # same loaded files, and the keys a later partial recapture needs.
      #
      # @api private
      # @param cached [Hash, nil] parsed coverage.json.
      # @return [Boolean]
      def cache_hit?(cached)
        cached && cached["digest"] == @digest && dependencies_match?(cached) &&
          cached.key?("load_methods") && cached.key?("timings") &&
          parallel_workers_match?(cached) && standalone_load_lines_current?(cached) &&
          partial_cache?(cached)
      end

      # True when `cached` has the keys {PARTIAL_CACHE_KEYS} names.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @return [Boolean]
      def partial_cache?(cached)
        PARTIAL_CACHE_KEYS.all? { |key| cached.key?(key) }
      end

      # Copies a saved map into this object. Boot mode keeps the load lines it
      # just read from the live boot.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @return [void]
      def apply_cache(cached)
        @map = cached["map"] || {}
        @timings = cached["timings"] || {}
        unless @boot_path
          @load_lines = Set.new(cached["load_lines"])
          @load_methods = Set.new(cached["load_methods"])
        end
        @failed_test_files = Array(cached["failed_test_files"])
        @failed_clean_tests = []
        @failed_clean_details = {}
        @clean_timeouts = {}
        @clean_check_seconds = nil
        @loaded_dependencies = cached["dependencies"] || {}
      end

      # How to recapture part of `cached`, or nil when the run must capture
      # every test. Nil covers a class-body edit, a moved line, a load-time
      # method whose body changed, a loaded file outside the run's sources, a
      # run input, and a change to which tests pair with a source (#421).
      #
      # @api private
      # @param cached [Hash, nil] parsed coverage.json.
      # @return [Hash, nil] `"removed"`, `"recapture"`, and `"changed_sources"`.
      def partial_plan(cached)
        return nil unless cached.is_a?(Hash) && partial_cache?(cached)
        return nil unless cached.key?("load_methods") && cached.key?("timings")
        return nil unless parallel_workers_match?(cached) && standalone_load_lines_current?(cached)
        return nil unless cached["run_inputs"] == run_inputs_digest
        return nil unless dependencies_match?(cached, except: source_rels.to_a)

        tests = cached["tests"]
        sources = cached["sources"]
        skeletons = cached["skeletons"]
        return nil unless tests.is_a?(Hash) && sources.is_a?(Hash) && skeletons.is_a?(Hash)

        current_tests = test_fingerprints
        current_sources = source_fingerprints
        current_skeletons = source_skeletons
        return nil unless current_sources.keys.sort == sources.keys.sort

        changed_sources = []
        current_sources.each do |rel, fingerprint|
          next if sources[rel] == fingerprint

          skeleton = current_skeletons[rel]
          return nil if skeleton.nil? || skeletons[rel] != skeleton

          changed_sources << rel
        end
        return nil unless load_method_bodies_unchanged?(cached, changed_sources)
        return nil if @boot_path && load_record_changed?(cached, changed_sources)

        old_rels = tests.keys
        new_rels = current_tests.keys
        return nil if pairing_sets_changed?(old_rels, new_rels)

        removed = old_rels - new_rels
        added = new_rels - old_rels
        edited = (new_rels & old_rels).select { |rel| tests[rel] != current_tests[rel] }
        failed = Array(cached["failed_test_files"]) & new_rels
        touching = tests_in_source_entries(cached["map"], changed_sources) & new_rels
        recapture = (added + edited + failed + touching).uniq
        # Keeping nothing is a full capture. It rebuilds load lines in one pass.
        return nil if removed.empty? && recapture.size == new_rels.size

        { "removed" => removed, "recapture" => recapture, "changed_sources" => changed_sources }
      end

      # Rebuilds the tests in `plan` and keeps the rest. Returns false when the
      # recaptured load snapshot disagrees with the cache: the caller then
      # captures every test. A kept test is not credited with another source's
      # load-only lines, because those entries are left as the full capture
      # stored them and {#record_paired_load_lines} does not add them back.
      #
      # @api private
      # @param plan [Hash] the plan from {#partial_plan}.
      # @param cached [Hash] parsed coverage.json.
      # @param after_fork [Proc, nil] boot-mode fork hook.
      # @return [Boolean] true when the partial map was saved.
      def apply_partial(plan, cached, after_fork)
        apply_cache(cached)
        removed = plan["removed"]
        recapture = plan["recapture"]
        (removed + recapture).each { |rel| drop_test(rel) }
        @failed_test_files -= (removed + recapture)
        @collect_load = true
        @seen_load_lines = nil
        @seen_load_methods = nil
        @test_paths.each do |path|
          capture_one(path, after_fork) if recapture.include?(relativize(path))
        end
        @collect_load = false
        return false if !@boot_path && recapture.any? && partial_load_diverged?(cached)

        refresh_dependency_fingerprints(plan["changed_sources"] + recapture)
        # A removed test keeps its fingerprint: a kept test may still load
        # that file, and the map does not record which test loaded what.
        sort_map_entries
        @phase_a_ran = true if recapture.any?
        warn_recaptured(recapture.size, @test_paths.size)
        checked = clean_check_test_paths
        verify_cached_clean(after_fork: after_fork,
                            test_paths: checked.reject { |test| recapture.include?(relativize(test)) })
        verify_combined_clean(after_fork: after_fork)
        warn_unchecked("coverage cache", checked.size)
        save
        true
      end

      # Removes `rel` from every map entry and forgets its timing.
      #
      # @api private
      # @param rel [String] project-relative test path.
      # @return [void]
      def drop_test(rel)
        @map.each_value { |tests| tests.delete(rel) if tests.is_a?(Array) }
        @map.delete_if { |_key, tests| !tests.is_a?(Array) || tests.empty? }
        @timings.delete(rel)
      end

      # Puts every map entry in `@test_paths` order, which is the order a full
      # capture records tests.
      #
      # @api private
      # @return [void]
      def sort_map_entries
        @map.each_value { |tests| tests.sort_by! { |test| test_index(test) } if tests.is_a?(Array) }
      end

      # True when this boot's load lines or load methods for `changed_sources`
      # differ from the cache. The method body then changed what ran at boot,
      # so a kept test's coverage is not trusted.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @param changed_sources [Array<String>] project-relative source paths.
      # @return [Boolean]
      def load_record_changed?(cached, changed_sources)
        wanted = changed_sources.to_set
        pick = lambda do |keys|
          Array(keys).select { |key| wanted.include?(key_source(key)) }.to_set
        end
        pick.call(@load_lines) != pick.call(cached["load_lines"]) ||
          pick.call(@load_methods) != pick.call(cached["load_methods"])
      end

      # True when a recaptured standalone test saw different load lines than
      # the cache recorded. The body change reached load time.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @return [Boolean]
      def partial_load_diverged?(cached)
        return false unless @seen_load_lines

        @seen_load_lines != Set.new(Array(cached["load_lines"])) ||
          @seen_load_methods != Set.new(Array(cached["load_methods"]))
      end

      # Writes the current fingerprint of each `rels` entry over the cached one.
      # Only a path the cache already lists is refreshed: a test file that no
      # test loads is tracked by the "tests" fingerprints, as on a full capture.
      #
      # @api private
      # @param rels [Array<String>] project-relative paths.
      # @return [void]
      def refresh_dependency_fingerprints(rels)
        rels.each do |rel|
          next unless @loaded_dependencies.key?(rel)

          abs = absolute(rel)
          next unless File.file?(abs)

          @loaded_dependencies[rel] = file_fingerprint(abs)
        end
      end

      # Tests in `map` entries whose source is one of `source_rels`.
      #
      # @api private
      # @param map [Hash, nil] a "file:line" => [test files] map.
      # @param source_rels [Array<String>] project-relative source paths.
      # @return [Array<String>] project-relative test paths.
      def tests_in_source_entries(map, source_rels)
        return [] unless map.is_a?(Hash)

        wanted = source_rels.to_set
        map.each_with_object([]) do |(key, tests), list|
          next unless wanted.include?(key_source(key))

          Array(tests).each { |test| list << test if test.is_a?(String) && !list.include?(test) }
        end
      end

      # True when the conventional pair for any run source is a different set
      # of tests than the cache was built with. Load-only lines would move.
      #
      # @api private
      # @param old_rels [Array<String>] project-relative tests in the cache.
      # @param new_rels [Array<String>] project-relative tests in this run.
      # @return [Boolean]
      def pairing_sets_changed?(old_rels, new_rels)
        old_set = old_rels.to_set
        new_set = new_rels.to_set
        source_rels.any? { |rel| paired_among(rel, old_set) != paired_among(rel, new_set) }
      end

      # Conventional tests for `source_rel` that are in `test_rels`.
      #
      # @api private
      # @param source_rel [String] project-relative source path.
      # @param test_rels [Set<String>] project-relative test paths.
      # @return [Array<String>]
      def paired_among(source_rel, test_rels)
        Pairing.infer_tests(source_rel, project_root: @project_root, prefer: @framework || "minitest")
               .select { |path| test_rels.include?(path) }
               .sort
      end

      # Project-relative paths of this run's sources.
      #
      # @api private
      # @return [Set<String>]
      def source_rels
        @source_rels ||= @source_paths.to_set { |path| relativize(absolute(path)) }
      end

      # Fingerprint of each test file, by project-relative path.
      #
      # @api private
      # @return [Hash{String => String}]
      def test_fingerprints
        @test_paths.to_h { |path| [relativize(absolute(path)), file_fingerprint(absolute(path))] }
      end

      # Digest of everything that forces a full capture except source and test
      # contents (#421). The source list is included, so adding a source still
      # captures every test: standalone capture loads every source.
      #
      # @api private
      # @return [String] hex digest.
      def run_inputs_digest
        digest = Digest::SHA256.new
        source_rels.to_a.sort.each do |rel|
          digest.update("source\0")
          digest.update(rel)
          digest.update("\0")
        end
        @require_paths.each { |path| digest_group(digest, "require", [digest_path(path)]) }
        digest_group(digest, "boot", [digest_path(@boot_path)]) if @boot_path
        ownership_paths.each do |rel|
          digest.update("owner\0")
          digest.update(rel)
          digest.update("\0")
        end
        @load_paths.sort.each { |load_path| digest.update("loadpath\0#{load_path}\0") }
        digest.update("framework\0#{@framework}\0")
        digest_test_seed(digest)
        digest.hexdigest
      end
    end
  end
end
