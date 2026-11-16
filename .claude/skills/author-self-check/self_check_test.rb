# frozen_string_literal: true

# Self-test: builds a throwaway repo and checks what self_check.rb reports.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class SelfCheckTest < Minitest::Test
  SCRIPT = File.expand_path("self_check.rb", __dir__)
  BASE_FILES = {
    "test/a_test.rb" => "assert_equal 1, x\nassert y\n",
    "README.md" => "Mutineer runs on Linux or macOS with Ruby 3.4.\n",
    "docs/index.md" => "Mutineer runs on Linux or macOS with Ruby 3.4.\n",
    "docs/rails.md" => "Install the gem in the test group.\n",
    "docs/rails.html" => "<p>Install the gem in the <b>test</b> group.</p>\n"
  }.freeze

  def run_in_repo(subdir: ".", extra_base: {})
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        sh = ->(*a) { system(*a, out: File::NULL, err: File::NULL) or raise a.join(" ") }
        sh.("git", "init", "-q", "-b", "main")
        sh.("git", "config", "user.email", "t@example.com")
        sh.("git", "config", "user.name", "t")
        BASE_FILES.merge(extra_base).each { |p, body| FileUtils.mkdir_p(File.dirname(p)) && File.write(p, body) }
        sh.("git", "add", ".")
        sh.("git", "commit", "-qm", "base")
        sh.("git", "checkout", "-qb", "feature")
        yield
        sh.("git", "add", ".")
        sh.("git", "commit", "-qm", "change (#42)")
        out, status = Open3.capture2e("ruby", SCRIPT, "main", chdir: subdir)
        return [out, status.exitstatus]
      end
    end
  end

  def test_flags_untracked_limitation_and_removed_assertion
    out, code = run_in_repo do
      File.write("test/a_test.rb", "assert_equal 1, x\n")
      File.write("NOTES.md", "This is a known limitation.\nDeferred to #77.\n")
    end
    assert_equal 1, code
    assert_includes out, "NOTES.md: This is a known limitation."
    refute_includes out, "Deferred to #77"
    assert_includes out, "test/a_test.rb: -1 net: assert y"
  end

  def test_changed_assertion_and_comment_skip_are_quiet
    out, code = run_in_repo do
      File.write("test/a_test.rb", "assert_equal 2, x\nassert y\n# we skip nothing here\n")
    end
    assert_equal 0, code, out
    assert_includes out, "net assertions removed, skips or timeouts added (0)"
  end

  def test_added_skip_is_flagged
    out, = run_in_repo { File.write("test/a_test.rb", "assert_equal 1, x\nassert y\nskip \"flaky\"\n") }
    assert_includes out, "test/a_test.rb: + skip \"flaky\""
  end

  def test_doc_sync_finds_stale_copy_and_untouched_twin
    out, = run_in_repo do
      File.write("README.md", "Mutineer runs on any platform.\n")
      File.write("docs/rails.md", "Install the gem in the development group.\n")
    end
    assert_includes out, "README.md: \"Mutineer runs on Linux or macOS with Ruby 3.4.\" still in docs/index.md"
    assert_includes out, "docs/rails.md: \"Install the gem in the test group.\" still in docs/rails.html"
    assert_includes out, "docs/rails.md changed, docs/rails.html did not"
    assert_includes out, "Answer each line"
  end

  def test_doc_sync_skips_the_mark_for_a_md_file
    out, = run_in_repo do
      Dir.mkdir("rake")
      File.write("rake/site.rb", "BUILD = %w[index.md]\n")
      File.write("README.md", "Mutineer runs on any platform.\n")
    end
    assert_includes out, "README.md: \"Mutineer runs on Linux or macOS with Ruby 3.4.\" still in docs/index.md"
    refute_includes out, "docs/index.md (named in rake/"
  end

  def test_marks_a_generated_txt_copy
    out, = run_in_repo do
      Dir.mkdir("rake")
      File.write("rake/site.rb", "OUT = 'llms-full.txt'\n")
      File.write("docs/llms-full.txt", "Install the gem in the test group.\n")
      File.write("docs/rails.md", "Install the gem in the development group.\n")
      File.write("docs/rails.html", "<p>Install the gem in the development group.</p>\n")
    end
    assert_includes out, "docs/llms-full.txt (named in rake/, rebuild if generated)"
  end

  def test_runs_from_a_subdirectory_and_keeps_non_ascii_paths
    cafe = { "docs/caf\u00e9.md" => "Mutineer runs on Linux or macOS with Ruby 3.4.\n" }
    out, = run_in_repo(subdir: "docs", extra_base: cafe) do
      File.write("docs/caf\u00e9.md", "Mutineer runs anywhere.\n")
    end
    assert_includes out, "docs/caf\u00e9.md: \"Mutineer runs on Linux or macOS with Ruby 3.4.\" still in"
  end

  def test_doc_sync_quiet_when_all_copies_change
    out, code = run_in_repo do
      File.write("README.md", "Mutineer runs on any platform.\n")
      File.write("docs/index.md", "Mutineer runs on any platform.\n")
      File.write("docs/rails.md", "Install the gem in the development group.\n")
      File.write("docs/rails.html", "<p>Install the gem in the development group.</p>\n")
    end
    assert_equal 0, code, out
    assert_includes out, "twin not changed (0)"
  end
end
