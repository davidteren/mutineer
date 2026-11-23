# frozen_string_literal: true

module Mutineer
  class CoverageMap
    # Loads the coverage cache or builds the map, and reuses a capture.
    #
    # Every run uses the cache flow: {#cached_or}, {#clean_check_test_paths}
    # and {#warn_unchecked}. Most other methods check a `--coverage-from`
    # capture and accept it only when it fits this run. {#source_fingerprints}
    # and {#key_source} are helpers that the cache checks also call.
    #
    # These are private methods of {Mutineer::CoverageMap}. They read and write
    # its instance variables.
    #
    # @api private
    module CaptureReuse
      private

      # Shared cache dance for both build paths: hit the digest-keyed cache, else
      # yield to populate @map and persist it. A digest match is not proof that
      # today's unmutated suite still passes, so a hit re-checks the tests a
      # mutant can run ({#clean_check_test_paths}), alone and then together (#398).
      #
      # @param after_fork [Proc, nil] boot-mode fork hook forwarded to a clean re-check.
      # @yield when the cache is missing or stale.
      # @return [Mutineer::CoverageMap] self.
      def cached_or(after_fork: nil)
        @digest = compute_digest
        return reuse_capture(after_fork) if @coverage_from

        cached = read_cache
        # A cache from before load methods (#209), test timings (#203), the
        # standalone load-line narrowing (#426), or partial recapture (#421)
        # rebuilds once. A cache that does not record this process's
        # PARALLEL_WORKERS value rebuilds too. Rails reads that value inside
        # parallelize, so a map from another worker count selects the wrong
        # tests. The daemon writes this same file. Boot mode reads its load
        # lines and methods from the live boot instead (#build_via_fork), but
        # its map from before #209 lacks the `def` lines of the methods each
        # test called.
        if cache_hit?(cached)
          apply_cache(cached)
          recaptured = retry_failed_captures(after_fork)
          warn_incomplete unless @failed_test_files.empty?
          checked = clean_check_test_paths
          # A retried capture already ran its test clean, so it does not run alone again.
          verify_cached_clean(after_fork: after_fork,
                              test_paths: checked.reject { |t| recaptured.include?(relativize(t)) })
          verify_combined_clean(after_fork: after_fork)
          warn_unchecked("coverage cache hit", checked.size)
          save
          return self
        end

        plan = partial_plan(cached)
        return self if plan && apply_partial(plan, cached, after_fork)

        yield
        verify_combined_clean(after_fork: after_fork)
        warn_unchecked("coverage capture", clean_check_test_paths.size, miss: true)
        save
        self
      end

      # The tests the clean check runs: the tests that cover a line of this run's
      # sources (#398). A mutant runs only tests from the map
      # ({JobPlan.coverage_selection}), so a test outside this set never runs
      # with a mutant and cannot change a verdict. Mutants exist only in the
      # sources, so only source keys count: standalone capture also maps the
      # other project files a test ran, its own file too. A map with no source
      # key keeps every test, because the daemon then runs every test for each
      # mutant. A new way to choose a mutant's tests must add those tests here,
      # or a red test could reach a mutant run.
      #
      # @api private
      # @return [Array<String>] the `--test` paths in this set, in their order.
      def clean_check_test_paths
        @source_rels ||= @source_paths.to_set { |p| relativize(absolute(p)) }
        covering = @map.each_with_object(Set.new) do |(key, tests), set|
          set.merge(tests) if @source_rels.include?(key_source(key))
        end
        return @test_paths if covering.empty?

        @test_paths.select { |t| covering.include?(relativize(t)) }
      end

      # Tells the user on stderr how many test files the clean check left out
      # (#398). Prints nothing when it left out none.
      #
      # @api private
      # @param label [String] what the run did: "coverage cache hit",
      #   "--coverage-from" or "coverage capture".
      # @param checked [Integer] the number of test files in {#clean_check_test_paths}.
      # @param miss [Boolean] true after a fresh capture, which ran every test
      #   alone, so only the together check leaves files out.
      # @return [void]
      def warn_unchecked(label, checked, miss: false)
        others = @test_paths.size - checked
        return unless others.positive?

        one = others == 1
        covering = checked == 1 ? "1 test file that covers" : "#{checked} test files that cover"
        head, tail =
          if miss
            ["the together check covers only the #{covering}", "ran alone only"]
          else
            ["the clean check ran the #{covering}",
             "never #{one ? 'runs' : 'run'} with a mutant and #{one ? 'was' : 'were'} not checked"]
          end
        warn "[mutineer] #{label}: #{head} the sources; #{others} other #{one ? 'test file' : 'test files'} #{tail}."
      end

      # Takes the map from the `--coverage-from` capture instead of capturing,
      # keeping only this run's sources, then runs the tests clean. A mutant runs
      # only the tests that cover its line, often one file alone, so each test
      # that covers one of this run's sources runs alone, as on a cache hit: a
      # test that fails alone here would otherwise kill every mutant it runs.
      # Those tests then run together. The other tests never run with a mutant
      # in this run, so they are not checked (#398).
      #
      # @api private
      # @param after_fork [Proc, nil] boot-mode fork hook.
      # @return [Mutineer::CoverageMap] self.
      # @raise [Mutineer::CoverageFromError] when the capture does not fit.
      def reuse_capture(after_fork)
        cached = accepted_capture
        sources = source_fingerprints.keys.to_set
        @map = cached["map"].select { |key, _| sources.include?(key_source(key)) }
        @timings = cached["timings"] || {}
        @failed_test_files = []
        @failed_clean_tests = []
        @failed_clean_details = {}
        @clean_timeouts = {}
        @clean_check_seconds = nil
        @loaded_dependencies = cached["dependencies"]
        checked = clean_check_test_paths
        verify_cached_clean(after_fork: after_fork, test_paths: checked)
        verify_combined_clean(after_fork: after_fork)
        warn_unchecked("--coverage-from", checked.size)
        save
        self
      end

      # The parsed `--coverage-from` capture, once it fits this run.
      #
      # @api private
      # @return [Hash] the parsed coverage.json.
      # @raise [Mutineer::CoverageFromError] when it cannot be read or does not fit.
      def accepted_capture
        if File.expand_path(@coverage_from) == File.expand_path(cache_path)
          raise CoverageFromError, "--coverage-from #{@coverage_from} is this run's own cache; give the run another --cache-dir"
        end

        cached = JSON.parse(File.read(@coverage_from, encoding: "UTF-8"))
        reason = capture_mismatch(cached)
        raise CoverageFromError, "--coverage-from #{@coverage_from} cannot be reused: #{reason}" if reason

        cached
      rescue SystemCallError, JSON::ParserError => e
        raise CoverageFromError, "--coverage-from #{@coverage_from} cannot be read: #{e.message}"
      end

      # Why a capture does not fit this run, or nil when it does.
      #
      # @api private
      # @param cached [Object] the parsed coverage.json.
      # @return [String, nil]
      def capture_mismatch(cached)
        return "it is not a coverage cache" unless cached.is_a?(Hash) && cached["map"].is_a?(Hash)
        unless cached["sources"] && cached["owners"] && cached["inputs"]
          return "it has no source fingerprints; capture it again with this version and --rails/--boot"
        end
        return "its entries are not the shape a coverage cache saves; capture it again" unless well_formed_capture?(cached)
        return "its tests, --require files, boot file, load paths, framework or test seed differ, or an older version made it; capture it again" unless cached["inputs"] == compute_digest(inputs_only: true)

        fingerprints = source_fingerprints
        missing = fingerprints.keys - cached["sources"].keys
        return "it was not captured over #{missing.join(', ')}" if missing.any?

        changed = fingerprints.reject { |rel, fingerprint| cached["sources"][rel] == fingerprint }.keys
        return "#{changed.join(', ')} changed since the capture" if changed.any?

        owners = ownership_paths - cached["owners"]
        return "#{owners.join(', ')} appeared since the capture and can own a split test" if owners.any?

        # The capture can list owners of sources outside this run, so compare
        # with the disk, not with this run's owners.
        gone = cached["owners"].reject { |rel| File.file?(absolute(rel)) }
        return "#{gone.join(', ')} disappeared since the capture and could own a split test" if gone.any?

        return "a file its tests loaded changed since the capture" unless dependencies_match?(cached)
        unless parallel_workers_match?(cached)
          return "it was captured with PARALLEL_WORKERS=#{cached['parallel_workers'].inspect}, " \
                 "this run has #{ENV.fetch('PARALLEL_WORKERS', nil).inspect}"
        end

        failed = Array(cached["failed_test_files"])
        return "capture failed for #{failed.join(', ')}" if failed.any?

        moved = load_mismatch(cached, fingerprints.keys.to_set)
        return nil if moved.empty?

        "lines of #{moved.join(', ')} ran at load in only one of the capture and this run: loading the capture's " \
          "other sources ran them. Under --strategy redefine, eager-load in both (config.eager_load = true)"
      end

      # True when every entry the reuse reads has the type {#save} writes, so a
      # hand-edited or foreign file is rejected with a reason, not a backtrace.
      #
      # @api private
      # @param cached [Hash] the parsed coverage.json.
      # @return [Boolean]
      def well_formed_capture?(cached)
        strings = ->(value) { value.is_a?(Array) && value.all?(String) }
        cached["inputs"].is_a?(String) && strings.(cached["owners"]) &&
          cached["sources"].is_a?(Hash) && cached["sources"].all? { |k, v| k.is_a?(String) && v.is_a?(String) } &&
          cached["map"].all? { |k, v| k.is_a?(String) && strings.(v) } &&
          %w[load_lines load_methods].all? { |key| cached[key].nil? || strings.(cached[key]) } &&
          (cached["timings"].nil? || (cached["timings"].is_a?(Hash) && cached["timings"].values.all? { |t| t.is_a?(Numeric) && t.finite? }))
      end

      # This run's sources whose load lines or load methods differ in the capture.
      #
      # @api private
      # @param cached [Hash] the parsed coverage.json.
      # @param sources [Set<String>] project-relative source paths.
      # @return [Array<String>] the sources that differ, sorted.
      def load_mismatch(cached, sources)
        owned = ->(keys) { Array(keys).select { |key| sources.include?(key_source(key)) }.to_set }
        moved = (owned.(cached["load_lines"]) ^ owned.(@load_lines)) + (owned.(cached["load_methods"]) ^ owned.(@load_methods))
        moved.map { |key| key_source(key) }.uniq.sort
      end

      # Fingerprint of each source, by project-relative path.
      #
      # @return [Hash{String => String}]
      def source_fingerprints
        @source_paths.to_h { |p| [relativize(absolute(p)), file_fingerprint(absolute(p))] }
      end

      # The source path of a "file:line" or "file:line:column" key.
      #
      # @param key [String] a map, load line or load method key.
      # @return [String]
      def key_source(key) = key.sub(/(?::\d+)+\z/, "")
    end
  end
end
