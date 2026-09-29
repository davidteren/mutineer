# frozen_string_literal: true

require "set"
require "open3"

module Mutineer
  # Maps each source file to the set of NEW-side line numbers changed since a
  # git ref.
  #
  # By parsing `git diff --unified=0`, this restricts mutations to only the
  # diff (issue #2): on a PR you care whether the changed code is tested, so
  # mutating just those lines is fast and actionable.
  #
  # git is an external tool, not a gem dependency — shelling out is fine. The
  # `parse` carries the logic; `git_diff` is injectable so it stays testable
  # without invoking git.
  module ChangedLines
    # Matches unified-diff hunks and captures the new-file start/count.
    HUNK = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

    module_function

    # Parses unified diff text into the set of NEW-side line numbers.
    #
    # With `--unified=0` each hunk's `+c,d` block is exactly the changed lines:
    # `c..c+d-1`. `d` absent means 1 line; `d == 0` is a pure deletion and
    # contributes nothing.
    #
    # @param diff_text [String] raw `git diff --unified=0` output.
    # @return [Set<Integer>] changed line numbers on the new side.
    def parse(diff_text)
      lines = Set.new
      diff_text.each_line do |row|
        m = HUNK.match(row) or next
        start = m[1].to_i
        count = m[2].nil? ? 1 : m[2].to_i
        next if count.zero?

        lines.merge(start...(start + count))
      end
      lines
    end

    # Builds a per-file map of changed new-side lines.
    #
    # @param ref [String] git ref to diff against.
    # @param files [Array<String>] source files to inspect.
    # @param project_root [String] repository root for `git -C`.
    # @param runner [#call] injectable diff producer.
    # @return [Hash<String, Set<Integer>>] absolute file path to changed lines.
    def for(ref:, files:, project_root:, runner: method(:git_diff))
      files.each_with_object({}) do |file, acc|
        abs = File.expand_path(file, project_root)
        acc[abs] = parse(runner.call(ref, abs, project_root))
      end
    end

    # Returns the stdout of `git -C <root> diff --unified=0 <ref> -- <file>`.
    # A file that git does not track has no diff, so `untracked_diff` supplies
    # one that marks every line new.
    #
    # A failure is warned, never silent: an empty result means "no changed
    # lines", which under `--since` removes every mutant for the file — a green
    # gate must not be manufactured by a broken diff without a trace.
    #
    # @param ref [String] git ref to diff against.
    # @param abs_file [String] absolute path of the file being diffed.
    # @param project_root [String] repository root for `git -C`.
    # @return [String] diff text, or `""` on failure (after a stderr warning).
    def git_diff(ref, abs_file, project_root)
      out, _err, status = Open3.capture3(
        "git", "-C", project_root, "diff", "--unified=0", ref, "--", abs_file
      )
      return(out.empty? ? untracked_diff(abs_file, project_root) : out) if status.success?

      warn "[mutineer] git diff failed for #{abs_file}; its lines will not be mutated (--since)"
      ""
    rescue StandardError => e
      warn "[mutineer] git diff failed for #{abs_file} (#{e.class}); its lines will not be mutated (--since)"
      ""
    end

    # Returns a diff that marks a file git does not know as entirely new. It
    # returns `""` when git tracks the file, when the file is empty, or when
    # the file cannot be read (after a warning). An untracked file has no diff
    # but every line is new; read as "unchanged", `--since` would score nothing
    # and a positive threshold would still exit 0.
    #
    # @param abs_file [String] absolute path of the file being diffed.
    # @param project_root [String] repository root for `git -C`.
    # @return [String] a one-hunk diff header, or `""`.
    def untracked_diff(abs_file, project_root)
      _out, _err, known = Open3.capture3(
        "git", "-C", project_root, "ls-files", "--error-unmatch", "--", abs_file
      )
      return "" if known.success?

      count = File.foreach(abs_file).count
      count.zero? ? "" : "@@ -0,0 +1,#{count} @@\n"
    rescue SystemCallError => e
      warn "[mutineer] cannot read #{abs_file} (#{e.class}); its lines will not be mutated (--since)"
      ""
    end
  end
end
