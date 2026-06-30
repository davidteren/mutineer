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
    #
    # @param ref [String] git ref to diff against.
    # @param abs_file [String] absolute path of the file being diffed.
    # @param project_root [String] repository root for `git -C`.
    # @return [String] diff text, or `""` on failure.
    def git_diff(ref, abs_file, project_root)
      out, _err, status = Open3.capture3(
        "git", "-C", project_root, "diff", "--unified=0", ref, "--", abs_file
      )
      status.success? ? out : ""
    rescue StandardError
      ""
    end
  end
end
