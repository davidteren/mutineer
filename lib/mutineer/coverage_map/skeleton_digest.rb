# frozen_string_literal: true

module Mutineer
  class CoverageMap
    # Computes the skeleton digest of each source, the method body digests and
    # the cache digest ({#compute_digest}). Also reads and writes the cache file
    # ({#cache_path}, {#read_cache}, {#save}) and prints three warnings
    # ({#warn_recaptured}, {#warn_external_sources}, {#warn_incomplete}).
    #
    # These are private methods of {Mutineer::CoverageMap}. They read and write
    # its instance variables.
    #
    # @api private
    module SkeletonDigest
      private

      # Skeleton digest of each source, by project-relative path. Nil when the
      # file does not parse: a partial recapture then does not run.
      #
      # @api private
      # @return [Hash{String => String, nil}]
      def source_skeletons
        @source_paths.to_h { |path| [relativize(absolute(path)), source_skeleton_digest(absolute(path))] }
      end

      # Digest of `abs` with each method body blanked, plus the line of every
      # `def`. Two files match when the edit is inside method bodies and no
      # line moved. A comment outside a body, a class-body statement, and an
      # added or removed line do not match.
      #
      # @api private
      # @param abs [String] absolute source path.
      # @return [String, nil] hex digest, or nil when the file cannot be parsed.
      def source_skeleton_digest(abs)
        source = File.binread(abs)
        result = Prism.parse(source)
        return nil unless result.errors.empty?

        ranges = []
        tuples = []
        each_def(result.value) do |node|
          loc = node.body&.location
          range = body_byte_range(node)
          ranges << range if range
          tuples << [node.location.start_line, node.location.start_column, loc&.start_line, loc&.end_line]
        end
        digest = Digest::SHA256.new
        digest.update(blank_method_bodies(source, ranges))
        tuples.sort.each do |tuple|
          digest.update("\0")
          digest.update(tuple.map { |part| part.nil? ? "-" : part.to_s }.join(":"))
        end
        digest.hexdigest
      rescue SystemCallError
        nil
      end

      # Byte range of the body of `node`, after its name and parameters. Nil
      # when the body is empty. A `def` with `rescue` or `ensure` has a
      # BeginNode body that starts at the `def` keyword, so the range starts
      # where the signature ends: a same-line name or parameter edit is not a
      # body edit.
      #
      # @api private
      # @param node [Prism::DefNode] a method definition.
      # @return [Array(Integer, Integer), nil] half-open byte range.
      def body_byte_range(node)
        loc = node.body&.location
        return nil unless loc

        signature_end = [node.name_loc, node.parameters&.location, node.rparen_loc].compact.map(&:end_offset).max
        start = [loc.start_offset, signature_end].max
        start < loc.end_offset ? [start, loc.end_offset] : nil
      end

      # `source` with every method-body byte range replaced by one marker.
      # Nested bodies are one marker: the outer range already covers them.
      #
      # @api private
      # @param source [String] source bytes.
      # @param ranges [Array<Array(Integer, Integer)>] half-open byte ranges.
      # @return [String] binary skeleton text.
      def blank_method_bodies(source, ranges)
        return source if ranges.empty?

        skip = Array.new(source.bytesize, false)
        ranges.each do |start, finish|
          next if start.negative? || finish > source.bytesize

          (start...finish).each { |index| skip[index] = true }
        end
        out = +"".b
        source.each_byte.with_index do |byte, index|
          if skip[index]
            out << 0 unless index.positive? && skip[index - 1]
          else
            out << byte
          end
        end
        out
      end

      # Yields each `def` in `node`, including defs nested in another body.
      #
      # @api private
      # @param node [Prism::Node, nil] syntax node.
      # @yieldparam node [Prism::DefNode]
      # @return [void]
      def each_def(node, &block)
        return unless node.is_a?(Prism::Node)

        block.call(node) if node.is_a?(Prism::DefNode)
        node.child_nodes.each { |child| each_def(child, &block) }
      end

      # True when every load-time method of `changed_sources` still has the
      # body the cache recorded. A different body can change a value other
      # tests read without those tests appearing in this source's map.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @param changed_sources [Array<String>] project-relative source paths.
      # @return [Boolean]
      def load_method_bodies_unchanged?(cached, changed_sources)
        stored = cached["load_method_bodies"]
        return false unless stored.is_a?(Hash)

        wanted = changed_sources.to_set
        stored.all? do |key, digest|
          next true unless wanted.include?(key_source(key))
          next false unless digest.is_a?(String)

          body_digest_at(key) == digest
        end
      end

      # Body digest of each method in {#load_methods}, keyed the same way.
      # `"missing"` marks a `def` the file no longer has at that line.
      #
      # @api private
      # @return [Hash{String => String}]
      def current_load_method_bodies
        @load_methods.to_h { |key| [key, body_digest_at(key) || "missing"] }
      end

      # Digest of the method body at the `def` named by `key`, in the file as
      # it is now. Nil when that `def` is gone or the file does not parse.
      #
      # @api private
      # @param key [String] a "file:line:column" load-method key.
      # @return [String, nil] hex digest.
      def body_digest_at(key)
        rel, line, column = split_method_key(key)
        text = method_bodies(rel)&.[]([line, column])
        return nil if text.nil?

        Digest::SHA256.hexdigest(text)
      end

      # Method bodies in `rel`, keyed by the `def` line and column Coverage uses.
      # Nil when the file does not parse.
      #
      # @api private
      # @param rel [String] project-relative source path.
      # @return [Hash{Array(Integer, Integer) => String}, nil]
      def method_bodies(rel)
        @method_bodies ||= {}
        return @method_bodies[rel] if @method_bodies.key?(rel)

        abs = absolute(rel)
        return @method_bodies[rel] = nil unless File.file?(abs)

        source = File.binread(abs)
        result = Prism.parse(source)
        return @method_bodies[rel] = nil unless result.errors.empty?

        found = {}
        each_def(result.value) do |node|
          loc = node.body&.location
          text = if loc && loc.end_offset > loc.start_offset
                   source.byteslice(loc.start_offset, loc.end_offset - loc.start_offset)
                 else
                   +""
                 end
          found[[node.location.start_line, node.location.start_column]] = text
        end
        @method_bodies[rel] = found
      rescue SystemCallError
        @method_bodies[rel] = nil
      end

      # Source path, `def` line, and `def` column of a load-method key.
      #
      # @api private
      # @param key [String] a "file:line:column" key.
      # @return [Array(String, Integer, Integer)]
      def split_method_key(key)
        rel = key_source(key)
        line, column = key.delete_prefix("#{rel}:").split(":").map(&:to_i)
        [rel, line, column]
      end

      # Tells the user how many test files a partial recapture ran again.
      # Prints nothing when every file was recaptured or none was: the first
      # is a full capture, and the second kept the whole map.
      #
      # @api private
      # @param recaptured [Integer] test files captured again.
      # @param total [Integer] test files in the run.
      # @return [void]
      def warn_recaptured(recaptured, total)
        kept = total - recaptured
        return unless recaptured.positive? && kept.positive?

        warn "[mutineer] coverage cache: recaptured #{recaptured} of #{total} test files; kept #{kept}."
      end

      # True when `cached` records the same +PARALLEL_WORKERS+ value this process
      # has now. Rails reads that variable inside +parallelize+ and can run one
      # test file in several workers. A missing key is a map saved before this
      # value was stored. In-process runs and the daemon write this same file.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @return [Boolean]
      def parallel_workers_match?(cached)
        cached.key?("parallel_workers") && cached["parallel_workers"] == ENV.fetch("PARALLEL_WORKERS", nil)
      end

      # Digest each file's ROLE + relative path + content length + content, plus
      # the load_paths. Without role/path/length delimiters the digest collides
      # (("ab","c") == ("a","bc")) and is blind to source/test role swaps, silently
      # accepting a stale cached map.
      #
      # @param inputs_only [Boolean] leave out the sources and their owners.
      def compute_digest(inputs_only: false)
        d = Digest::SHA256.new
        digest_group(d, "source", @source_paths) unless inputs_only
        digest_group(d, "test", @test_paths)
        # One group per file: digest_group sorts, and the load order matters.
        @require_paths.each { |p| digest_group(d, "require", [digest_path(p)]) }
        digest_group(d, "boot", [digest_path(@boot_path)]) if @boot_path
        (inputs_only ? [] : ownership_paths).each do |rel|
          d.update("owner\0")
          d.update(rel)
          d.update("\0")
        end
        @load_paths.sort.each { |lp| d.update("loadpath\0#{lp}\0") }
        digest_extra_load_dirs(d)
        d.update("framework\0#{@framework}\0")
        digest_test_seed(d)
        d.hexdigest
      end

      # Adds the test seed inputs to `digest`. The seed sets the test order, and
      # the order can change which lines run (#282). Minitest: the configured
      # seed. A test helper that changes SEED is not digested, like any other
      # helper edit. RSpec: the pinned seed, SPEC_OPTS, and the project `.rspec`
      # files. `~/.rspec` and a `config.seed` in a spec helper are not digested;
      # a helper edit is seen when that file is part of the capture.
      # {#compute_digest} and {#run_inputs_digest} share this, so a seed change
      # never reaches a partial recapture (#421).
      #
      # @api private
      # @param digest [Digest::SHA256] the digest to update.
      # @return [void]
      def digest_test_seed(digest)
        if @framework == "rspec"
          digest.update("seed\0#{MinitestIntegration::PINNED_SEED}\0#{ENV['SPEC_OPTS']}\0")
          %w[.rspec .rspec-local].each do |name|
            path = File.join(@project_root, name)
            digest.update("rspec-opts\0#{name}\0")
            digest.update(File.file?(path) ? File.binread(path) : "")
            digest.update("\0")
          end
        else
          digest.update("seed\0#{MinitestIntegration.seed}\0")
        end
      end

      # Longer source files that can take a split test from a configured source.
      # Only their presence is digested. A content edit of a sibling does not
      # change pairing, and it does not rebuild coverage. Each directory is
      # listed once, even when many sources share it. A concern also digests
      # longer files in its namespace directory, because those files can own a
      # namespace split name (#408). A model does not digest a concern file:
      # the model keeps a split file it already pairs with. A pack source also
      # digests the longer files of the same names inside its pack (#494).
      #
      # @return [Array<String>] project-relative paths, sorted.
      def ownership_paths
        root = File.expand_path(@project_root)
        listings = {}
        paths = @source_paths.flat_map do |source|
          rel = relativize(absolute(source))
          next [] if rel.start_with?("/")

          base, = Pairing.logical_path(rel)
          bases = [base]
          ns = Pairing.namespace_base(rel)
          bases << ns if ns
          bases.uniq.flat_map { |logical| owner_files(root, logical, listings) } + pack_owner_files(rel, root, listings)
        end
        paths.uniq.sort
      end

      # {#owner_files} inside the pack of a pack source, with the pack path in
      # front, because the pack rule of {Pairing.infer_tests} reads the pack
      # folder as the root (#494). `[]` for a source outside `packs/`.
      #
      # @param rel [String] project-relative source path.
      # @param root [String] expanded project root.
      # @param listings [Hash{String => Array<String>}] directory children, filled once.
      # @return [Array<String>] project-relative paths.
      def pack_owner_files(rel, root, listings)
        pack, inner = Pairing.pack_split(rel)
        return [] unless pack

        base, = Pairing.logical_path(inner)
        bases = [base, Pairing.namespace_base(inner)].compact.uniq
        bases.flat_map { |logical| owner_files(File.join(root, pack), logical, listings) }
             .map { |path| File.join(pack, path) }
      end

      # Longer `.rb` files that can own a split name of `base`.
      #
      # @param root [String] expanded project root.
      # @param base [String] logical source path without extension.
      # @param listings [Hash{String => Array<String>}] directory children, filled once.
      # @return [Array<String>] project-relative paths.
      def owner_files(root, base, listings)
        name = File.basename(base)
        dir = File.dirname(base)
        folders = [dir == "." ? nil : dir]
        %w[app lib].each { |prefix| folders << (dir == "." ? prefix : File.join(prefix, dir)) }
        folders.uniq.flat_map do |folder|
          abs = folder ? File.join(root, folder) : root
          entries = listings.fetch(abs) do
            listings[abs] = File.directory?(abs) ? Dir.children(abs).map { |entry| FsPath.read(entry) } : []
          end
          entries.filter_map do |entry|
            next unless entry.end_with?(".rb")

            stem = entry.delete_suffix(".rb")
            next unless stem.start_with?("#{name}_") && stem.length > name.length

            folder ? File.join(folder, entry) : entry
          end
        end
      end

      # boot_path and require_paths are require-style paths (e.g. "config/environment",
      # no extension); resolve one to the file `require` loads: the path itself, then
      # ".rb", then a native extension. A folder of the same name (lib/my_gem/ next to
      # lib/my_gem.rb) is not the file.
      def digest_path(path)
        ["", ".rb", ".#{RbConfig::CONFIG['DLEXT']}"].map { |ext| "#{path}#{ext}" }
                                                  .find { |p| File.file?(absolute(p)) } || "#{path}.rb"
      end

      # Groups a digest with its role and paths.
      #
      # @api private
      # @param digest [String] digest string.
      # @param role [String] digest role.
      # @param paths [Array<String>] paths in the digest group.
      # @return [Array(String, String, Array<String>)] grouped digest data.
      def digest_group(digest, role, paths)
        paths.sort.each do |p|
          # Bytes, not a locale read: a magic-comment encoding such as EUC-JP
          # is not valid UTF-8, and the digest is of the file's bytes (#346).
          content = File.binread(absolute(p))
          digest.update(role)
          digest.update("\0")
          digest.update(relativize(absolute(p)))
          digest.update("\0")
          digest.update(content.bytesize.to_s)
          digest.update("\0")
          digest.update(content)
          digest.update("\0")
        end
      end

      # A configured source that resolves outside project_root would silently be
      # dropped (its coverage relativizes to an absolute path). Warn instead.
      def warn_external_sources
        @source_paths.each do |p|
          next unless relativize(absolute(p)).start_with?("/")

          warn "[mutineer] source #{p} is outside project root #{@project_root}; " \
               "its coverage will be ignored"
        end
      end

      # Returns the cache path.
      #
      # @api private
      # @return [String] cache file path.
      def cache_path = File.join(@cache_dir, "coverage.json")

      # Reads the coverage cache.
      #
      # @api private
      # @return [Hash, nil] cached payload.
      def read_cache
        return nil unless File.exist?(cache_path)

        JSON.parse(File.read(cache_path, encoding: "UTF-8"))
      rescue JSON::ParserError
        nil # corrupt cache: rebuild from scratch
      end

      # Saves the coverage cache.
      #
      # @api private
      # @return [void]
      def save
        return unless @failed_clean_tests.empty?

        FileUtils.mkdir_p(@cache_dir)
        sources = source_fingerprints
        tests = test_fingerprints
        data = { "digest" => @digest, "failed_test_files" => @failed_test_files,
                 "dependencies" => @loaded_dependencies, "map" => @map,
                 "load_lines" => @load_lines.to_a.sort, "load_methods" => @load_methods.to_a.sort,
                 "timings" => @timings, "parallel_workers" => ENV.fetch("PARALLEL_WORKERS", nil),
                 NARROW_LOAD_LINES => true, "run_inputs" => run_inputs_digest,
                 "sources" => sources, "skeletons" => source_skeletons,
                 "tests" => tests, "load_method_bodies" => current_load_method_bodies,
                 "work_tree" => @work_tree&.merge("own" => own_rels, "during_run" => during_run_rels(sources.merge(tests))) }
        data[LOAD_LINE_PAIRS] = load_line_pairs unless @boot_path
        if @boot_path
          data.merge!("inputs" => compute_digest(inputs_only: true), "sources" => sources,
                      "owners" => ownership_paths)
        end
        tmp = "#{cache_path}.tmp"
        File.write(tmp, JSON.generate(data))
        File.rename(tmp, cache_path) # atomic swap
      end

      # Warns when coverage capture was incomplete.
      #
      # @api private
      # @return [void]
      def warn_incomplete
        warn "[mutineer] cached coverage map may be incomplete; these test files " \
             "failed to contribute: #{@failed_test_files.join(', ')}"
      end
    end
  end
end
