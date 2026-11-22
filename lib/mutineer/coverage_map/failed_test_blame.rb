# frozen_string_literal: true

module Mutineer
  class CoverageMap
    # Decides if a failed test file blames a source file. A blamed source
    # cannot be captured, so its mutants are not run against that test.
    #
    # These are private methods of {Mutineer::CoverageMap}. They read and write
    # its instance variables.
    #
    # @api private
    module FailedTestBlame
      private

      # Source rel-paths that received coverage from any successful capture.
      def covered_source_files
        @map.keys.map { |k| k.rpartition(":").first }.to_set
      end

      # True when a failed test file pairs with `source_rel` by convention.
      # Exact `_test` / `_spec` / `test_` names match by basename, as before.
      # A split `<name>_*_test.rb` matches only in the mirrored test directory,
      # and only when no longer source file owns that name (#87). The answer
      # is kept for this map, so a later delete does not move the failure.
      #
      # @param source_rel [String] project-relative source path.
      # @return [Boolean]
      def failed_test_blames?(source_rel)
        @blame_for ||= {}
        return @blame_for[source_rel] if @blame_for.key?(source_rel)

        @blame_for[source_rel] = exact_failed_test?(source_rel) || split_failed_test?(source_rel)
      end

      # True when a failed exact `_test` / `_spec` / `test_` file pairs with
      # this source. An `app/` or `lib/` source only accepts a `test/` or
      # `spec/` file from its mirrored directory, so
      # `test/foo/bar_upsert_test.rb` does not taint `app/other/bar_upsert.rb`.
      # A concern also accepts the same names at its namespace path, but only
      # when it has no test at its `concerns/` path, as in {Pairing.infer_tests}.
      # Any other source still matches by basename. A fixture under
      # `test/fixtures/` and an explicit test both name their source that way.
      #
      # @param source_rel [String] project-relative source path.
      # @return [Boolean]
      def exact_failed_test?(source_rel)
        name = File.basename(source_rel, ".rb")
        base, lib = Pairing.logical_path(source_rel)
        ns = Pairing.namespace_base(source_rel)
        ns = nil if ns && own_concern_test?(source_rel, ns)
        @failed_test_files.any? do |test_path|
          next false unless failed_test_target_name(test_path) == name

          rel = relativize(test_path)
          dir = File.dirname(rel)
          if app_or_lib_source?(source_rel) && conventional_test_dir?(dir)
            mirrored_test_dir?(rel, base, lib) || spec_mirror?(rel, base, lib) ||
              namespace_mirror?(rel, ns)
          else
            true
          end
        end
      end

      # True when `test_rel` sits in the namespace mirror of a concern.
      # The check is path only. A test at the concerns path does not block it.
      #
      # @param test_rel [String] project-relative test path.
      # @param ns_base [String, nil] namespace base from {Pairing.namespace_base}.
      # @return [Boolean]
      def namespace_mirror?(test_rel, ns_base)
        return false unless ns_base

        dirs = [Pairing.mirror_dir("test", ns_base), Pairing.mirror_dir("spec", ns_base)]
        dirs.include?(File.dirname(test_rel))
      end

      # True when pairing finds a test for this concern at its `concerns/`
      # path, so a test at its namespace path is not paired with it.
      #
      # @param source_rel [String] project-relative concern path.
      # @param ns_base [String] namespace base from {Pairing.namespace_base}.
      # @return [Boolean]
      def own_concern_test?(source_rel, ns_base)
        Pairing.infer_tests(source_rel, project_root: @project_root)
               .any? { |t| !namespace_mirror?(t, ns_base) }
      end

      # True when pairing gives this source a mirrored test directory.
      #
      # @param source_rel [String] project-relative source path.
      # @return [Boolean]
      def app_or_lib_source?(source_rel)
        source_rel.start_with?("app/", "lib/")
      end

      # Basename a failed test file would pair with, before the directory check.
      #
      # @param test_path [String]
      # @return [String]
      def failed_test_target_name(test_path)
        name = File.basename(test_path, ".rb")
        case name
        when /_(test|spec)\z/ then name.sub(/_(test|spec)\z/, "")
        when "test_helper" then name
        else name.delete_prefix("test_")
        end
      end

      # True when `dir` is `test`, `spec`, or a directory under one of them.
      #
      # @param dir [String] project-relative directory.
      # @return [Boolean]
      def conventional_test_dir?(dir)
        dir == "test" || dir == "spec" || dir.start_with?("test/", "spec/")
      end

      # True when a failed split test file pairs with this source. Directory and
      # the longer-source check match {Pairing}, so a test outside the mirror, or
      # one owned by `user_session.rb`, does not taint `user.rb`. A concern with
      # no test at its `concerns/` path also accepts a split name at its
      # namespace path (#408). A longer concern owns that name only when it
      # pairs with the file. A namespace spec leaves split names unpaired, so
      # a failed split does not mark the concern.
      #
      # @param source_rel [String] project-relative source path.
      # @return [Boolean]
      def split_failed_test?(source_rel)
        base, lib = Pairing.logical_path(source_rel)
        return true if failed_split_in?(base, lib, concern: false)

        ns = Pairing.namespace_base(source_rel)
        return false unless ns
        return false if own_concern_test?(source_rel, ns)
        return false if namespace_spec?(source_rel)

        failed_split_in?(ns, false, concern: true)
      end

      # True when the concern's namespace pairing is one spec file.
      # Split names do not join a spec, so a failed split must not mark it.
      #
      # @param source_rel [String] project-relative concern path.
      # @return [Boolean]
      def namespace_spec?(source_rel)
        Pairing.infer_tests(source_rel, project_root: @project_root).any? { |t| t.end_with?("_spec.rb") }
      end

      # True when one failed split file in the mirror of `base` pairs with it.
      #
      # @param base [String] logical source path without extension.
      # @param lib [Boolean] whether the source originated from lib/.
      # @param concern [Boolean] true for a concern's namespace mirror, so a
      #   longer concern file can own the name.
      # @return [Boolean]
      def failed_split_in?(base, lib, concern:)
        name = File.basename(base)
        @failed_test_files.any? do |t|
          test_rel = relativize(t)
          entry = File.basename(test_rel)
          next false unless Pairing.split_entry?(entry, name)
          next false unless mirrored_test_dir?(test_rel, base, lib)
          next false if Pairing.claimed_by_longer_source?(@project_root, base, entry, File.dirname(test_rel))
          next false if concern && Pairing.claimed_by_longer_concern?(@project_root, base, entry)

          true
        end
      end

      # True when `test_rel` sits in a mirrored test directory for `base`.
      #
      # @param test_rel [String] project-relative test path.
      # @param base [String] logical source path without extension.
      # @param lib [Boolean] whether the source originated from lib/.
      # @return [Boolean]
      def mirrored_test_dir?(test_rel, base, lib)
        dirs = [Pairing.mirror_dir("test", base)]
        dirs << Pairing.mirror_dir("test/lib", base) if lib
        dirs.include?(File.dirname(test_rel))
      end

      # True when `test_rel` sits in a mirrored spec directory for `base`.
      # Split Minitest names stay in {#mirrored_test_dir?}. An exact `_spec`
      # file uses this directory.
      #
      # @param test_rel [String] project-relative test path.
      # @param base [String] logical source path without extension.
      # @param lib [Boolean] whether the source originated from lib/.
      # @return [Boolean]
      def spec_mirror?(test_rel, base, lib)
        dirs = [Pairing.mirror_dir("spec", base)]
        dirs << Pairing.mirror_dir("spec/lib", base) if lib
        dirs.include?(File.dirname(test_rel))
      end
    end
  end
end
