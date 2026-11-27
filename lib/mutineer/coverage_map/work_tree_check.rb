# frozen_string_literal: true

module Mutineer
  class CoverageMap
    # Refuses a saved map when a file changed that no other cache check sees
    # (#595): a view, a fixture, a lock file, a Ruby file that no test had
    # loaded. The saved map records the commit of its run and a fingerprint of
    # each path that differed from that commit ({WorkTree.record}).
    #
    # These are private methods of {Mutineer::CoverageMap}. They read its
    # instance variables.
    #
    # @api private
    module WorkTreeCheck
      private

      # Paths named in one stderr line.
      WORK_TREE_NAMES = 3

      # The line for a run that reuses a map with no git answer at all. #602
      # tracks the limits of this check. The remedy is to delete the cache
      # file, or for `--coverage-from` to capture again.
      NO_GIT_NOTE = "git gives no answer for this project (no repository, git is not installed, or git ignores or " \
                    "refuses the folder), so an edit to a view, a fixture or a lock file is not seen; after such " \
                    "an edit, %<remedy>s (https://github.com/davidteren/mutineer/issues/602)"

      # The reason when git cannot give the list of changed files.
      GIT_FAILED = "git could not list the changed files (run git status in the project to see why)"

      # True when `record` has the shape {#save} writes. The commit must be a
      # full commit id ({WorkTree::COMMIT_ID}) or nil: the cache file can be
      # edited, and the commit goes to git as an argument.
      #
      # @api private
      # @param record [Object] the `"work_tree"` entry of a parsed coverage.json.
      # @return [Boolean]
      def well_formed_work_tree?(record)
        commit = record.is_a?(Hash) ? record["commit"] : nil
        record.is_a?(Hash) && (commit.nil? || (commit.is_a?(String) && commit.match?(WorkTree::COMMIT_ID))) &&
          record["dirty"].is_a?(Hash) &&
          record["dirty"].all? { |rel, print| rel.is_a?(String) && (print.nil? || print.is_a?(String)) } &&
          (record["own"].nil? || (record["own"].is_a?(Array) && record["own"].all?(String)))
      end

      # Why the work tree does not allow a reuse of `cached`, and a note for a
      # reuse that goes on. Compares the saved record with `@work_tree`, the
      # record of this run, so the state it accepts is the state {#save}
      # writes. Prints nothing.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json with a well-formed `"work_tree"`.
      # @param saved_name [String] what the user calls `cached`: "the saved map" or "the capture".
      # @return [Array] the reason or nil, the note or nil, and for changed
      #   files the full sorted path list (absent otherwise), for `--verbose`.
      def work_tree_refusal(cached, saved_name = "the saved map")
        commit = cached["work_tree"]["commit"]
        mine = @work_tree["commit"]
        if commit.nil?
          return ["#{saved_name} records no git commit, and the project has one now", nil] if mine
          unless WorkTree.inside?(@project_root)
            remedy = @coverage_from ? "capture it again" : "delete #{relativize(absolute(cache_path))}"
            return [nil, format(NO_GIT_NOTE, remedy: remedy)]
          end

          return ["git gives no commit for this project (it has no commit yet, or git failed), so the changed files cannot be listed", nil]
        end
        return [GIT_FAILED, nil] unless mine

        now = mine == commit ? @work_tree["dirty"].keys : WorkTree.changed_since(commit, @project_root)
        if now
          changes = unscoped_changes(cached, now)
          return [changed_files_reason(changes, saved_name), nil, changes.keys]
        end
        return [GIT_FAILED, nil] if WorkTree.commit?(commit, @project_root)

        ["the commit of #{saved_name} is not in this clone (a shallow clone, or a commit that no branch holds now; " \
         "fetch the full history, in GitHub Actions with fetch-depth: 0)", nil]
      end

      # The reason text for changed files: one path, or a count and up to
      # {WORK_TREE_NAMES} paths. Nil when nothing changed.
      #
      # @api private
      # @param changes [Hash{String => Symbol}] path => `:changed`, `:no_print` or `:during_run`, sorted by path.
      # @param saved_name [String] "the saved map" or "the capture".
      # @return [String, nil]
      def changed_files_reason(changes, saved_name)
        return nil if changes.empty?

        shown = changes.keys.first(WORK_TREE_NAMES).map { |rel| printable_path(rel) }
        more = changes.size - shown.size
        one = changes.size == 1
        what = one ? shown.first : "#{changes.size} files (#{shown.join(', ')}#{" and #{more} more" if more.positive?})"
        causes = changes.values.uniq
        if causes == [:no_print]
          "#{what} cannot be fingerprinted (a folder, a nested repository, a changed submodule, an unreadable file " \
            "or a name that is not UTF-8): add #{one ? 'it' : 'them'} to .gitignore or remove #{one ? 'it' : 'them'}"
        elsif causes == [:during_run]
          "#{what} changed while the last run was in progress"
        else
          "#{what} changed since #{saved_name}, and Mutineer cannot tell which tests #{one ? 'it affects' : 'they affect'}"
        end
      end

      # The changed paths that no other cache check handles, each with its
      # cause. A source or a test of this run, and a Ruby file the saved map
      # loaded, are left to their own checks, unless that check cannot see
      # the change: the file changed while the last run was in progress, and
      # the cache saved its new fingerprint (`:during_run`, #604).
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @param now [Array<String>] paths that differ from the saved commit now.
      # @return [Hash{String => Symbol}] path relative to the project root => cause, sorted by path.
      def unscoped_changes(cached, now)
        saved = cached["work_tree"]["dirty"]
        saved_own = Array(cached["work_tree"]["own"])
        scoped = source_rels.to_set + test_fingerprints.keys
        scoped.merge(cached["dependencies"].keys) if cached["dependencies"].is_a?(Hash)
        (now | saved.keys).sort.each_with_object({}) do |rel, changes|
          mine = @work_tree["dirty"]
          current = mine.key?(rel) ? mine[rel] : WorkTree.fingerprint(@project_root, rel)
          next if (saved[rel] && saved[rel] == current) || own_rels.include?(rel) || saved_own.include?(rel) || own_path?(rel)

          if scoped.include?(rel)
            changes[rel] = :during_run unless cache_sees_change?(cached, rel)
          else
            changes[rel] = current.nil? || (saved.key?(rel) && saved[rel].nil?) ? :no_print : :changed
          end
        end
      end

      # True when no fingerprint the cache saved for `rel` equals the file
      # now, so the digest, {Cache#partial_plan} or {Cache#dependencies_match?}
      # handles the change. False when one of them equals it: the record of
      # the last run says the file changed, so the cache took that print
      # during the run (#604). One differing print is not enough: a source's
      # loaded-file print is taken at its capture, its source print at save,
      # and {Cache#partial_plan} reads only the second.
      #
      # @api private
      # @param cached [Hash] parsed coverage.json.
      # @param rel [String] path relative to the project root.
      # @return [Boolean]
      def cache_sees_change?(cached, rel)
        prints = %w[sources tests dependencies].filter_map { |key| cached[key][rel] if cached[key].is_a?(Hash) }
        abs = absolute(rel)
        return true if prints.empty? || !File.file?(abs)

        current = file_fingerprint(abs)
        prints.none?(current)
      rescue SystemCallError
        true
      end

      # `rel` with each control character as `?`: a file name can hold a
      # newline or an escape character, and it goes into one stderr line.
      #
      # @api private
      # @param rel [String] path relative to the project root.
      # @return [String]
      def printable_path(rel) = rel.gsub(/[[:cntrl:]]/, "?")

      # A mutant temp file beside a source (OrphanGuard::TEMP_BASENAME). A
      # concurrent run can leave one there while this run takes its record.
      MUTANT_TEMP = %r{(?:\A|/)\.?mutineer_(?:mutant|daemon)\d{8}-[^/]*\.rb\z}

      # True for a path in a place where Mutineer keeps its own state, which
      # the tests of a project do not read: the `.mutineer` folder of the
      # project root, `.mutineer.yml` in the project root (Config's file
      # name), a file-swap lock or backup beside a source
      # (FileSwap::LOCK_DIR_NAME, FileSwap::BACKUP_SUFFIX), and a mutant temp
      # file ({MUTANT_TEMP}).
      #
      # @api private
      # @param rel [String] path relative to the project root.
      # @return [Boolean]
      def own_path?(rel)
        rel == ".mutineer.yml" || rel.start_with?(".mutineer/") || "/#{rel}".include?("/.mutineer/file-swap-locks/") ||
          rel.end_with?(".mutineer-backup") || rel.match?(MUTANT_TEMP)
      end

      # The files this run writes or reads for itself, relative to the project
      # root: its cache file and the temporary file of {#save}, the
      # `--coverage-from` file, and the report and baseline. {#save} keeps the
      # list in the record, so a later run does not take the report of this
      # run for a project change.
      #
      # A file that does not exist yet, such as the report before the run
      # writes it, is placed by the real path of its folder, so a folder
      # reached through a symlink still gives the path git lists.
      #
      # @api private
      # @return [Array<String>]
      def own_rels
        @own_rels ||= ([cache_path, "#{cache_path}.tmp", @coverage_from] + @own_paths).compact.map do |path|
          abs = absolute(path)
          relativize(File.join(ProjectPath.root_real(File.dirname(abs)), File.basename(abs)))
        end
      end
    end
  end
end
