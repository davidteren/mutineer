# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ChangedLinesTest < Minitest::Test
  CL = Mutineer::ChangedLines

  def test_parse_single_hunk_with_count
    diff = "@@ -1,0 +5,3 @@\n+a\n+b\n+c\n"
    assert_equal Set[5, 6, 7], CL.parse(diff)
  end

  # A failed per-file diff must warn, never silently mean "no changed lines" —
  # under --since that silence would drop every mutant for the file untraced.
  def test_git_diff_failure_warns_and_returns_empty
    Dir.mktmpdir do |not_a_repo|
      out = nil
      _stdout, err = capture_io do
        out = CL.git_diff("HEAD", File.join(not_a_repo, "f.rb"), not_a_repo)
      end
      assert_equal "", out
      assert_match(/git diff failed for .*f\.rb; its lines will not be mutated/, err)
    end
  end

  def test_parse_hunk_without_new_count_means_one_line
    diff = "@@ -10 +12 @@\n-old\n+new\n"
    assert_equal Set[12], CL.parse(diff)
  end

  def test_parse_pure_deletion_contributes_no_lines
    diff = "@@ -5,3 +4,0 @@\n-a\n-b\n-c\n"
    assert_equal Set.new, CL.parse(diff)
  end

  def test_parse_deletion_only_hunk_old_side_ignored
    diff = "@@ -7,2 +6 @@\n-gone\n+kept\n"
    assert_equal Set[6], CL.parse(diff)
  end

  def test_parse_multiple_hunks
    diff = <<~DIFF
      diff --git a/f.rb b/f.rb
      index 111..222 100644
      --- a/f.rb
      +++ b/f.rb
      @@ -1 +1 @@
      -x
      +x2
      @@ -10,0 +20,2 @@ def foo
      +new1
      +new2
      @@ -30,2 +40,0 @@
      -dead1
      -dead2
    DIFF
    assert_equal Set[1, 20, 21], CL.parse(diff)
  end

  def test_parse_empty_diff
    assert_equal Set.new, CL.parse("")
  end

  def test_parse_ignores_non_hunk_lines_that_look_similar
    diff = "+@@ not a hunk header\n@@ -1 +3,2 @@\n+a\n+b\n"
    assert_equal Set[3, 4], CL.parse(diff)
  end

  def test_for_maps_abs_path_to_changed_set_via_injected_runner
    root = "/proj"
    diffs = {
      "/proj/lib/a.rb" => "@@ -1 +1 @@\n+a\n",
      "/proj/lib/b.rb" => "@@ -1,0 +3,2 @@\n+b\n+c\n"
    }
    runner = ->(_ref, abs, _root) { diffs.fetch(abs, "") }

    result = CL.for(ref: "main", files: ["lib/a.rb", "lib/b.rb"], project_root: root, runner: runner)

    assert_equal Set[1], result["/proj/lib/a.rb"]
    assert_equal Set[3, 4], result["/proj/lib/b.rb"]
  end

  def test_for_file_absent_from_diff_is_empty_set
    runner = ->(_ref, _abs, _root) { "" }
    result = CL.for(ref: "main", files: ["lib/x.rb"], project_root: "/proj", runner: runner)
    assert_equal Set.new, result["/proj/lib/x.rb"]
  end
end
