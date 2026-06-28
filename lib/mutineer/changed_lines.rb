# frozen_string_literal: true

require "set"
require "open3"

module Mutineer
  # Maps each source file to the set of NEW-side line numbers that changed since a
  # given git ref, by parsing `git diff --unified=0`. Used to restrict mutations
  # to only the diff (issue #2): on a PR you care whether the changed code is
  # tested, so mutating just those lines is fast and actionable.
  #
  # git is an external tool, not a gem dependency — shelling out is fine. The pure
  # `parse` carries the logic; `git_diff` is injectable so it stays testable
  # without invoking git.
  module ChangedLines
    HUNK = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

    module_function

    # Parse `git diff --unified=0` output into the set of NEW-side line numbers
    # added/modified. With --unified=0 each hunk's `+c,d` block is exactly the
    # changed lines: c..c+d-1. `d` absent means 1 line; `d == 0` is a pure
    # deletion and contributes nothing.
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

    # { absolute_file_path => Set<Integer> } of changed new-side lines per file.
    # `runner` is injected so tests can supply canned diff text per file.
    def for(ref:, files:, project_root:, runner: method(:git_diff))
      files.each_with_object({}) do |file, acc|
        abs = File.expand_path(file, project_root)
        acc[abs] = parse(runner.call(ref, abs, project_root))
      end
    end

    # stdout of `git -C <root> diff --unified=0 <ref> -- <file>`, "" on failure.
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
