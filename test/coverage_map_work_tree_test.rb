# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"
require "json"
require "open3"

# The coverage cache refuses a saved map when a project file changed that no
# other cache check covers (#595): a view, a fixture, a lock file. Each test
# builds a small git project where one test reads such files, and asserts
# which test files were captured and the exact stderr line.
class CoverageMapWorkTreeTest < Minitest::Test
  SOURCES = %w[lib/card.rb lib/shelf.rb].freeze
  TESTS = %w[test/card_test.rb test/page_test.rb test/shelf_test.rb].freeze
  # The line of lib/card.rb that only the page test reaches, and only when a
  # file it reads says "strict".
  STRICT_LINE = "lib/card.rb:4"
  SENTINEL = 'if ENV["MUTINEER_SENTINEL"]; _mode = defined?(Coverage) && Coverage.running? ? "capture" : "clean"; ' \
             'File.write(ENV["MUTINEER_SENTINEL"], "#{Process.pid} #{File.basename(__FILE__)} #{_mode}\n", mode: "a"); end'
  CHANGED = "[mutineer] coverage cache: %s changed since the saved map, and Mutineer cannot tell which tests " \
            "it affects; capturing every test."

  Result = Struct.new(:map, :err, :captured)

  def setup
    @tmp = File.realpath(Dir.mktmpdir("mutineer-595"))
    @root = File.join(@tmp, "app")
    @scratch = File.join(@tmp, "scratch")
    FileUtils.mkdir_p([@root, @scratch])
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def git(dir, *args)
    _out, err, status = Open3.capture3("git", "-C", dir, "-c", "user.email=t@example.test", "-c", "user.name=t",
                                       "-c", "commit.gpgsign=false", *args)
    assert status.success?, "git #{args.join(' ')}: #{err}"
  end

  def commit_all(dir = @root, message = "change")
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", message)
  end

  def path(rel) = File.join(@root, rel)

  def write(rel, text)
    FileUtils.mkdir_p(File.dirname(path(rel)))
    File.write(path(rel), text)
  end

  def write_app(git_repo: true)
    write("lib/card.rb", <<~RUBY)
      class Card
        def self.title(mode)
          if mode == "strict"
            "STRICT"
          else
            "plain"
          end
        end

        def self.other
          1
        end
      end
    RUBY
    write("lib/shelf.rb", "class Shelf\n  def self.size\n    3\n  end\nend\n")
    write("lib/util.rb", "module Util\n  def self.one = 1\nend\n")
    write("lib/unused.rb", "module Unused; end\n")
    write("app/views/show.html.erb", "plain\n")
    write("test/fixtures/cards.yml", "mode: plain\n")
    write("Gemfile.lock", "GEM\n  specs:\n")
    write(".env", "MODE=plain\n")
    write("README.md", "readme\n")
    write(".gitignore", "tmp/\n")
    write("test/card_test.rb", <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/card"
      require_relative "../lib/util"
      #{SENTINEL}
      class CardTest < Minitest::Test
        def test_other; assert_equal Util.one, Card.other; end
      end
    RUBY
    write("test/page_test.rb", <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/card"
      #{SENTINEL}
      class PageTest < Minitest::Test
        def test_page
          view = File.read(File.expand_path("../app/views/show.html.erb", __dir__)).strip
          fixture = File.read(File.expand_path("fixtures/cards.yml", __dir__))[/mode: (\\w+)/, 1]
          lock = File.read(File.expand_path("../Gemfile.lock", __dir__)).include?("strictgem") ? "strict" : "plain"
          # Other files a test can read; the KTD6 rows name them.
          ENV.fetch("MUTINEER_READS", "").split(":").each { |rel| File.read(File.expand_path("../\#{rel}", __dir__)) }
          [view, fixture, lock].each { |mode| assert Card.title(mode) }
        end
      end
    RUBY
    write("test/shelf_test.rb", <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/shelf"
      #{SENTINEL}
      class ShelfTest < Minitest::Test
        def test_size; assert_equal 3, Shelf.size; end
      end
    RUBY
    return unless git_repo

    git(@root, "init", "-q")
    commit_all(@root, "base")
  end

  def build(cache: ".mutineer", tests: TESTS, sources: SOURCES, root: @root, **options)
    sentinel = File.join(@scratch, "sentinel")
    File.write(sentinel, "")
    ENV["MUTINEER_SENTINEL"] = sentinel
    map = Mutineer::CoverageMap.new(source_paths: sources, test_paths: tests, cache_dir: File.join(root, cache),
                                    project_root: root, **options)
    _out, err = capture_io { map.build_or_load }
    rows = File.readlines(sentinel, chomp: true).map(&:split)
    Result.new(map, err, rows.select { |row| row[2] == "capture" }.map { |row| "test/#{row[1]}" }.uniq.sort)
  ensure
    ENV.delete("MUTINEER_SENTINEL")
  end

  def fresh = build(cache: ".mutineer/fresh")

  # :hit, :partial or :full, from the test files the run captured.
  def kind(result, tests = TESTS)
    return :hit if result.captured.empty?

    result.captured == tests.sort ? :full : :partial
  end

  def lines(result) = result.err.lines.map(&:chomp).grep(/coverage cache:/)

  def edit_cache(cache = path(".mutineer/coverage.json"))
    data = JSON.parse(File.read(cache))
    yield data
    File.write(cache, JSON.generate(data))
  end

  # The three file kinds of #595. Each edit changes which line of Card the
  # page test reaches. The map after the run equals a fresh capture.
  def test_a_view_a_fixture_and_a_lock_file_edit_each_capture_every_test
    { "app/views/show.html.erb" => "strict\n", "test/fixtures/cards.yml" => "mode: strict\n",
      "Gemfile.lock" => "GEM\n  specs:\n    strictgem (1.0)\n" }.each do |rel, text|
      teardown
      setup
      write_app
      build
      write(rel, text)
      run = build
      assert_equal :full, kind(run), rel
      assert_equal [format(CHANGED, rel)], lines(run), rel
      assert_equal ["test/page_test.rb"], run.map.map[STRICT_LINE], rel
      assert_equal fresh.map.map[STRICT_LINE], run.map.map[STRICT_LINE], rel
    end
  end

  # The partial path: a method-body edit beside a view edit (the Fizzy case of
  # the 11-F measurement) captures every test, not only the source's tests.
  def test_a_body_edit_beside_a_view_edit_captures_every_test
    write_app
    build
    write("lib/shelf.rb", File.read(path("lib/shelf.rb")).sub("    3\n", "    2 + 1\n"))
    write("app/views/show.html.erb", "strict\n")
    run = build
    assert_equal :full, kind(run)
    assert_equal [format(CHANGED, "app/views/show.html.erb")], lines(run)
    assert_equal fresh.map.map[STRICT_LINE], run.map.map[STRICT_LINE]
  end

  # Each row is written out with its result: a path kind and a change kind.
  # A row that captures every test names the path in the line. Rows that do
  # not capture every test print no reason line.
  TABLE = {
    "nothing changes" => [:hit, nil],
    "a view is edited" => [:full, "app/views/show.html.erb", nil, ->(t) { t.write("app/views/show.html.erb", "x\n") }],
    "a fixture is edited" => [:full, "test/fixtures/cards.yml", nil, ->(t) { t.write("test/fixtures/cards.yml", "x\n") }],
    "a lock file is edited" => [:full, "Gemfile.lock", nil, ->(t) { t.write("Gemfile.lock", "x\n") }],
    "a dotfile is edited" => [:full, ".env", nil, ->(t) { t.write(".env", "MODE=strict\n") }],
    "a docs file is edited" => [:full, "README.md", nil, ->(t) { t.write("README.md", "x\n") }],
    "a Ruby file no test loads is edited" => [:full, "lib/unused.rb", nil, ->(t) { t.write("lib/unused.rb", "module Unused; X = 1; end\n") }],
    "a file with a space in its name is added" => [:full, "app/views/my page.erb", nil, ->(t) { t.write("app/views/my page.erb", "x\n") }],
    "a nested file is added" => [:full, "app/views/cards/deep/x.erb", nil, ->(t) { t.write("app/views/cards/deep/x.erb", "x\n") }],
    "a view is deleted" => [:full, "app/views/show.html.erb", nil, ->(t) { File.delete(t.path("app/views/show.html.erb")) }],
    "a view is renamed" => [:full, "2 files (app/views/show.html.erb, app/views/shown.html.erb)", nil,
                            ->(t) { t.git(t.path(""), "mv", "app/views/show.html.erb", "app/views/shown.html.erb") }],
    "a view edit is staged" => [:full, "app/views/show.html.erb", nil,
                                ->(t) { t.write("app/views/show.html.erb", "x\n"); t.git(t.path(""), "add", "-A") }],
    "a view edit is committed" => [:full, "app/views/show.html.erb", nil,
                                   ->(t) { t.write("app/views/show.html.erb", "x\n"); t.commit_all }],
    "a view's mode changes" => [:full, "app/views/show.html.erb", nil, ->(t) { File.chmod(0o755, t.path("app/views/show.html.erb")) }],
    "a view edited before the first run, no change after" => [:hit, nil, ->(t) { t.write("app/views/show.html.erb", "x\n") }],
    "a view edited before the first run, committed after" => [:hit, nil, ->(t) { t.write("app/views/show.html.erb", "x\n") },
                                                              ->(t) { t.commit_all }],
    "a view edited before the first run, restored after" => [:full, "app/views/show.html.erb",
                                                             ->(t) { t.write("app/views/show.html.erb", "x\n") },
                                                             ->(t) { t.git(t.path(""), "checkout", "--", ".") }],
    "a view edited before the first run, its mode changed after" => [:full, "app/views/show.html.erb",
                                                                     ->(t) { t.write("app/views/show.html.erb", "x\n") },
                                                                     ->(t) { File.chmod(0o755, t.path("app/views/show.html.erb")) }],
    "an untracked file at the first run is deleted" => [:full, "app/views/new.erb", ->(t) { t.write("app/views/new.erb", "x\n") },
                                                        ->(t) { File.delete(t.path("app/views/new.erb")) }],
    "a branch switch with the same tree" => [:hit, nil, nil, ->(t) { t.git(t.path(""), "checkout", "-qb", "other") }],
    "an ignored file is edited (limit #602)" => [:hit, nil, nil, ->(t) { t.write("tmp/data.yml", "x\n") }],
    "a run source body is edited" => [:partial, nil, nil,
                                      ->(t) { t.write("lib/shelf.rb", "class Shelf\n  def self.size\n    2 + 1\n  end\nend\n") }],
    "a run source body edit is committed" => [:partial, nil, nil,
                                              lambda { |t|
                                                t.write("lib/shelf.rb", "class Shelf\n  def self.size\n    2 + 1\n  end\nend\n")
                                                t.commit_all
                                              }],
    "a run source edited before the first run, committed after" => [:hit, nil,
                                                                     ->(t) { t.write("lib/shelf.rb", "class Shelf\n  def self.size\n    2 + 1\n  end\nend\n") },
                                                                     ->(t) { t.commit_all }],
    "a run test is edited" => [:partial, nil, nil, ->(t) { t.write("test/shelf_test.rb", "#{File.read(t.path('test/shelf_test.rb'))}# c\n") }],
    # A loaded Ruby file is left to the dependency check: it captures every
    # test with no reason line, as before #595 (limit #603).
    "a Ruby file a test loads is edited" => [:full, nil, nil, ->(t) { t.write("lib/util.rb", "module Util\n  def self.one = 1 * 1\nend\n") }],
    "an edited view with the assume-unchanged flag" => [:full, "app/views/show.html.erb", nil,
                                                        lambda { |t|
                                                          t.git(t.path(""), "update-index", "--assume-unchanged", "app/views/show.html.erb")
                                                          t.write("app/views/show.html.erb", "x\n")
                                                        }],
    "an edited view with the skip-worktree flag" => [:full, "app/views/show.html.erb", nil,
                                                     lambda { |t|
                                                       t.git(t.path(""), "update-index", "--skip-worktree", "app/views/show.html.erb")
                                                       t.write("app/views/show.html.erb", "x\n")
                                                     }],
    "a view that a sparse checkout removes" => [:full, "app/views/show.html.erb", nil,
                                                ->(t) { t.git(t.path(""), "sparse-checkout", "set", "--no-cone", "/*", "!/app/views/") }],
    "a view with the assume-unchanged flag, edited before the first run" => [:hit, nil,
                                                                              lambda { |t|
                                                                                t.git(t.path(""), "update-index", "--assume-unchanged", "app/views/show.html.erb")
                                                                                t.write("app/views/show.html.erb", "x\n")
                                                                              }]
  }.freeze

  def test_the_table_of_path_kinds_and_change_kinds
    TABLE.each do |name, (expect, named, before, between)|
      teardown
      setup
      write_app
      before&.call(self)
      build
      between&.call(self)
      run = build
      assert_equal expect, kind(run), name
      if named
        assert_includes run.err, "coverage cache: #{named} changed since the saved map", name
        assert_includes run.err, "capturing every test.", name
      else
        refute_includes run.err, "capturing every test", name
      end
    end
  end

  def test_a_change_outside_the_project_root_is_not_seen_and_one_inside_is
    write_app(git_repo: false)
    File.write(File.join(@tmp, "README.md"), "outer\n")
    git(@tmp, "init", "-q")
    commit_all(@tmp, "base")
    build
    File.write(File.join(@tmp, "README.md"), "changed\n")
    assert_equal :hit, kind(build), "limit #602: outside the project root"
    write("app/views/show.html.erb", "strict\n")
    run = build
    assert_equal :full, kind(run)
    assert_equal [format(CHANGED, "app/views/show.html.erb")], lines(run)
  end

  def test_five_changed_files_are_counted_and_verbose_lists_each
    write_app
    build
    names = %w[a.erb b.yml c.lock d.txt e.json]
    names.each { |rel| write(rel, "x\n") }
    summary = "[mutineer] coverage cache: 5 files (a.erb, b.yml, c.lock and 2 more) changed since the saved map, " \
              "and Mutineer cannot tell which tests they affect; capturing every test."
    assert_equal [summary], lines(build)

    teardown
    setup
    write_app
    build
    names.each { |rel| write(rel, "x\n") }
    assert_equal [summary] + names.map { |rel| "[mutineer] coverage cache:   #{rel}" }, lines(build(verbose: true)).first(6)
  end

  def test_a_saved_commit_that_is_not_in_the_clone_captures_every_test
    write_app
    build
    edit_cache { |data| data["work_tree"]["commit"] = "#{'0' * 39}1" }
    run = build
    assert_equal :full, kind(run)
    assert_equal ["[mutineer] coverage cache: the commit of the saved map is not in this clone (a shallow clone, " \
                  "or a commit that no branch holds now; fetch the full history, in GitHub Actions with " \
                  "fetch-depth: 0); capturing every test."], lines(run)
  end

  # The cache file is a trust boundary: a saved commit that is not a full
  # commit id is a malformed cache. It never reaches git as an option.
  def test_a_hostile_saved_commit_is_a_malformed_cache_and_reaches_no_git_command
    write_app
    build
    pwned = File.join(@scratch, "pwned")
    edit_cache { |data| data["work_tree"]["commit"] = "--output=#{pwned}" }
    run = build
    assert_equal :full, kind(run)
    assert_empty lines(run)
    refute_path_exists pwned
  end

  def test_git_that_cannot_list_the_changed_files_captures_every_test
    write_app
    build
    run = Mutineer::WorkTree.stub(:git, ["", nil]) { build }
    assert_equal :full, kind(run)
    assert_equal ["[mutineer] coverage cache: git could not list the changed files (run git status in the " \
                  "project to see why; the check needs git 2.24 or later); capturing every test."], lines(run)
  end

  # git older than 2.24 refuses --end-of-options. Each run captures every
  # test with the line that names git 2.24; none raises or reuses the map.
  def test_a_git_older_than_2_24_captures_every_test_with_a_line
    write_app
    real = Open3.capture2("sh", "-c", "command -v git").first.strip
    bin = File.join(@scratch, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "git"), <<~SH)
      #!/bin/sh
      for arg in "$@"; do [ "$arg" = "--end-of-options" ] && { echo "unknown option" >&2; exit 129; }; done
      exec "#{real}" "$@"
    SH
    File.chmod(0o755, File.join(bin, "git"))
    path = ENV.fetch("PATH")
    ENV["PATH"] = "#{bin}:#{path}"
    build
    2.times do
      run = build
      assert_equal :full, kind(run)
      assert_equal ["[mutineer] coverage cache: git could not list the changed files (run git status in the " \
                  "project to see why; the check needs git 2.24 or later); capturing every test."], lines(run)
    end
  ensure
    ENV["PATH"] = path if path
  end

  # When git fails at every command, the line blames git, not a shallow clone.
  def test_git_that_fails_after_the_record_does_not_blame_a_shallow_clone
    write_app
    build
    record = Mutineer::WorkTree.record(@root)
    run = Mutineer::WorkTree.stub(:changed_since, nil) do
      Mutineer::WorkTree.stub(:commit?, false) do
        Mutineer::WorkTree.stub(:head, nil) { build(work_tree: record) }
      end
    end
    assert_equal :full, kind(run)
    assert_equal ["[mutineer] coverage cache: git could not list the changed files (run git status in the " \
                  "project to see why; the check needs git 2.24 or later); capturing every test."], lines(run)
  end

  # A view edited during the app boot, after the record: this run sees it.
  def test_a_view_edited_during_the_boot_captures_every_test_in_that_run
    write_app
    build
    record = Mutineer::WorkTree.record(@root)
    write("app/views/show.html.erb", "strict\n")
    run = build(work_tree: record)
    assert_equal :full, kind(run)
    assert_equal [format(CHANGED, "app/views/show.html.erb")], lines(run)
    assert_equal ["test/page_test.rb"], run.map.map[STRICT_LINE]
  end

  # A saved path outside the root is a malformed cache: the check never reads it.
  def test_a_saved_path_outside_the_root_is_a_malformed_cache
    ["../outside.yml", "/etc/hosts", "lib/../../outside.yml", "a\0b.yml"].each do |bad|
      teardown
      setup
      write_app
      build
      edit_cache { |data| data["work_tree"]["dirty"][bad] = "x" }
      run = build
      assert_equal :full, kind(run), bad
      assert_empty lines(run), bad
    end
  end

  # A listing that failed when the map was saved leaves a record with no
  # commit. While git still has one, the line blames the listing.
  def test_a_record_with_no_commit_while_git_has_one_says_git_could_not_list
    write_app
    Mutineer::WorkTree.stub(:changed_since, nil) { build }
    run = Mutineer::WorkTree.stub(:changed_since, nil) { build }
    assert_equal :full, kind(run)
    assert_equal ["[mutineer] coverage cache: git could not list the changed files (run git status in the " \
                  "project to see why; the check needs git 2.24 or later); capturing every test."], lines(run)
  end

  # A name that is not UTF-8, after HEAD moved, beside a UTF-8 name that is
  # not ASCII: the run captures every test, and the line can join the two.
  def test_a_name_that_is_not_utf8_after_head_moved_cannot_be_fingerprinted
    write_app
    build
    write("README.md", "moved\n")
    write("café.yml", "x\n")
    commit_all
    listing = Mutineer::WorkTree.method(:changed_since)
    bad = lambda do |commit, root|
      paths = listing.call(commit, root)
      paths && paths + ["bad\xFF.yml".b]
    end
    run = Mutineer::WorkTree.stub(:changed_since, bad) { build }
    assert_equal :full, kind(run)
    assert_includes run.err, "bad?.yml"
    assert_includes run.err, "capturing every test."
  end

  def test_a_map_saved_with_no_git_and_a_project_with_a_commit_now_captures_every_test
    write_app(git_repo: false)
    build
    git(@root, "init", "-q")
    commit_all(@root, "base")
    run = build
    assert_equal :full, kind(run)
    assert_equal ["[mutineer] coverage cache: the saved map records no git commit, and the project has one now; " \
                  "capturing every test."], lines(run)
  end

  def test_a_repository_with_no_commit_captures_every_test_each_run
    write_app(git_repo: false)
    git(@root, "init", "-q")
    build
    run = build
    assert_equal :full, kind(run)
    assert_equal ["[mutineer] coverage cache: git gives no commit for this project (it has no commit yet, or " \
                  "git failed), so the changed files cannot be listed; capturing every test."], lines(run)
  end

  NO_GIT = "[mutineer] coverage cache: git gives no answer for this project (no repository, git is not installed, " \
           "or git ignores or refuses the folder), so an edit to a view, a fixture or a lock file is not seen; " \
           "after such an edit, delete .mutineer/coverage.json (https://github.com/davidteren/mutineer/issues/602)."

  # No git: the reuse goes on (limit #602) and says what it cannot see.
  def test_a_project_with_no_git_reuses_the_map_and_says_what_it_cannot_see
    write_app(git_repo: false)
    first = build
    refute_includes first.err, "git gives no answer", "the first run captures every test: no note"
    write("app/views/show.html.erb", "strict\n")
    run = build
    assert_equal :hit, kind(run)
    assert_equal [NO_GIT], lines(run)
  end

  def test_the_no_git_note_is_not_printed_when_the_run_captures_every_test_for_another_reason
    write_app(git_repo: false)
    build
    write("lib/card.rb", "#{File.read(path('lib/card.rb'))}\n# a new line\n")
    run = build
    assert_equal :full, kind(run)
    refute_includes run.err, "git gives no answer"
  end

  # The note prints only where a reuse happens; a partial recapture is one.
  def test_the_no_git_note_is_printed_on_a_partial_recapture
    write_app(git_repo: false)
    build
    write("lib/shelf.rb", "class Shelf\n  def self.size\n    2 + 1\n  end\nend\n")
    run = build
    assert_equal :partial, kind(run)
    assert_includes lines(run), NO_GIT
  end

  def test_the_reason_line_comes_before_the_unchecked_line
    write_app
    write("test/none_test.rb", "require \"minitest/autorun\"\nclass NoneTest < Minitest::Test\n  def test_ok; assert true; end\nend\n")
    commit_all
    tests = TESTS + ["test/none_test.rb"]
    build(tests: tests)
    write("app/views/show.html.erb", "strict\n")
    run = build(tests: tests)
    reason = run.err.index("show.html.erb changed since the saved map")
    unchecked = run.err.index("[mutineer] coverage capture:")
    assert reason && unchecked, run.err
    assert_operator reason, :<, unchecked
  end

  # A view edited while the capture runs, after the test that reads it ran:
  # the record is from before, so the next run sees the edit.
  def test_a_view_edited_while_the_capture_runs_is_seen_by_the_next_run
    write_app
    write("test/z_test.rb", <<~RUBY)
      require "minitest/autorun"
      #{SENTINEL}
      if ENV["PROBE_EDIT"]
        File.write(File.expand_path("../app/views/show.html.erb", __dir__), "strict\\n")
      end
      class ZTest < Minitest::Test
        def test_ok; assert true; end
      end
    RUBY
    commit_all
    tests = TESTS + ["test/z_test.rb"]
    ENV["PROBE_EDIT"] = "1"
    build(tests: tests)
    ENV.delete("PROBE_EDIT")
    run = build(tests: tests)
    assert_equal :full, kind(run, tests)
    assert_equal [format(CHANGED, "app/views/show.html.erb")], lines(run)
  ensure
    ENV.delete("PROBE_EDIT")
  end

  # The record the check accepts is the record the cache saves: a run given a
  # record that says the view is strict, with the view plain on disk, cannot
  # reuse a map saved from plain.
  def test_the_record_a_caller_passes_is_the_one_the_check_uses_and_save_writes
    write_app
    build
    write("app/views/show.html.erb", "strict\n")
    record = Mutineer::WorkTree.record(@root)
    git(@root, "checkout", "--", ".")
    run = build(work_tree: record)
    assert_equal :full, kind(run)
    assert_equal [format(CHANGED, "app/views/show.html.erb")], lines(run)
    saved = JSON.parse(File.read(path(".mutineer/coverage.json")))["work_tree"]
    assert_equal record["dirty"], saved["dirty"]
    # The view is plain again, so it differs from the saved record.
    assert_equal :full, kind(build)
  end

  def test_a_cache_with_no_or_a_malformed_work_tree_record_captures_every_test_with_no_line
    [->(data) { data.delete("work_tree") }, ->(data) { data["work_tree"]["dirty"] = [] },
     ->(data) { data["work_tree"] = "abc" }].each_with_index do |change, i|
      teardown
      setup
      write_app
      build
      edit_cache(&change)
      run = build
      assert_equal :full, kind(run), i
      assert_empty lines(run), i
    end
  end

  # A test that the saved map holds and this run leaves out has no other
  # check: a kept test can still load it (KTD11).
  def test_an_edit_to_a_source_or_a_test_that_this_run_leaves_out_captures_every_test
    write_app
    build
    write("test/shelf_test.rb", "#{File.read(path('test/shelf_test.rb'))}# c\n")
    tests = TESTS - ["test/shelf_test.rb"]
    run = build(tests: tests)
    assert_equal :full, kind(run, tests)
    assert_equal [format(CHANGED, "test/shelf_test.rb")], lines(run)

    # A source of the saved map is in its loaded files too: the capture
    # loads every source. So the dependency check catches this edit, with no
    # reason line (limit #603).
    teardown
    setup
    write_app
    build
    assert_includes JSON.parse(File.read(path(".mutineer/coverage.json")))["dependencies"].keys, "lib/shelf.rb"
    write("lib/shelf.rb", "class Shelf\n  def self.size\n    2 + 1\n  end\nend\n")
    assert_equal :full, kind(build(sources: ["lib/card.rb"]))
  end

  # The cache folder is the project root: its coverage.json and the temporary
  # file are this run's own files.
  def test_a_cache_in_the_project_root_reuses_the_map
    write_app
    build(cache: ".")
    assert_equal :hit, kind(build(cache: "."))
    assert_equal :hit, kind(build(cache: "."))
  end

  # Mutineer's own files never count as changed (KTD6), even when a test reads
  # them. A file of the same name in another folder is a normal project file.
  def test_mutineers_own_files_are_left_out_and_files_of_the_same_name_elsewhere_are_not
    {
      ".mutineer.yml" => :hit, ".mutineer/baseline.json" => :hit,
      "lib/.mutineer/file-swap-locks/abc" => :hit, "report.json" => :hit,
      "lib/.mutineer_mutant20261127-1-abc.rb" => :hit, "lib/card.rb.mutineer-backup" => :hit,
      "tmp2/mutineer-callback-growth20261127-1-abc.log" => :hit, "tmp2/mutineer-callback-growth.log" => :full,
      "app/.mutineer.yml" => :full, "test/.mutineer/options.yml" => :full
    }.each do |rel, expect|
      teardown
      setup
      write_app
      write(rel, "a\n")
      commit_all unless rel.start_with?(".mutineer/", "lib/.mutineer/")
      ENV["MUTINEER_READS"] = rel
      own = { own_paths: [path("report.json")] }
      build(**own)
      write(rel, "b\n")
      run = build(**own)
      assert_equal expect, kind(run), rel
      assert_equal [format(CHANGED, rel)], lines(run), rel if expect == :full
    ensure
      ENV.delete("MUTINEER_READS")
    end
  end

  # The report of the last run is an own file of the saved map, so a run that
  # does not name it still reuses the map.
  def test_the_report_of_the_last_run_is_not_a_change_for_a_run_that_does_not_name_it
    write_app
    report = path("report.json")
    build(own_paths: [report])
    File.write(report, "{}")
    assert_equal :hit, kind(build(own_paths: [report]))
    File.write(report, "{\"again\": 1}")
    assert_equal :hit, kind(build)
  end

  # The callback-growth log a reload or daemon run makes matches the own-file pattern.
  def test_the_callback_growth_log_name_is_an_own_file_name
    log = Mutineer::JobPlan.create_callback_growth_log
    assert_match Mutineer::CoverageMap::WorkTreeCheck::CALLBACK_LOG, File.basename(log)
  ensure
    File.delete(log) if log
  end

  # A report whose name is not UTF-8 is not an own file: the save leaves it
  # out, and a listed name that is not UTF-8 cannot be fingerprinted.
  def test_a_report_whose_name_is_not_utf8_is_left_out_and_never_matches
    write_app
    raw = path("report-\xFF.json").b
    build(own_paths: [raw])
    assert_equal %w[.mutineer/coverage.json .mutineer/coverage.json.tmp], JSON.parse(File.read(path(".mutineer/coverage.json")))["work_tree"]["own"]
    listing = Mutineer::WorkTree.method(:changed_since)
    with_report = ->(commit, root) { listing.call(commit, root)&.push("report-\xFF.json".b) }
    run = Mutineer::WorkTree.stub(:changed_since, with_report) { build(own_paths: [raw]) }
    assert_equal :full, kind(run)
    assert_includes run.err, "report-?.json cannot be fingerprinted"
  end

  # An own path that is not UTF-8 converts to the text of another name. The
  # other file is still a project file, and a non-UTF-8 name that converts to
  # an own-file pattern is not an own file.
  def test_a_file_whose_name_equals_a_converted_own_name_or_pattern_is_still_seen
    write_app
    write("x?", "a\n")
    commit_all
    ENV["MUTINEER_READS"] = "x?"
    own = { own_paths: [path("x\xFF").b] }
    build(**own)
    write("x?", "b\n")
    run = build(**own)
    assert_equal :full, kind(run)
    assert_equal [format(CHANGED, "x?")], lines(run)

    build
    listing = Mutineer::WorkTree.method(:changed_since)
    fake = ->(commit, root) { listing.call(commit, root)&.push("tmp2/mutineer-callback-growth20261127-1-\xFF.log".b) }
    run = Mutineer::WorkTree.stub(:changed_since, fake) { build }
    assert_equal :full, kind(run)
    assert_includes run.err, "mutineer-callback-growth20261127-1-?.log cannot be fingerprinted"
  ensure
    ENV.delete("MUTINEER_READS")
  end

  # The report does not exist yet when the first run saves its map. Through a
  # project root reached by a symlink, it still saves as the path git lists.
  def test_a_report_that_does_not_exist_yet_is_saved_as_an_own_path_through_a_symlinked_root
    write_app
    link = File.join(@tmp, "link")
    File.symlink(@root, link)
    build(root: link, own_paths: [File.join(link, "report.json")])
    assert_includes JSON.parse(File.read(path(".mutineer/coverage.json")))["work_tree"]["own"], "report.json"
    File.write(path("report.json"), "{}")
    assert_equal :hit, kind(build(root: link))
  end

  def test_an_untracked_nested_repository_captures_every_test_on_each_run
    write_app
    FileUtils.mkdir_p(path("vendor/x"))
    git(path("vendor/x"), "init", "-q")
    write("vendor/x/a", "1\n")
    build
    run = build
    assert_equal :full, kind(run)
    assert_equal ["[mutineer] coverage cache: vendor/x/ cannot be fingerprinted (a folder, a nested repository, " \
                  "a changed submodule, an unreadable file or a name that is not UTF-8): add it to .gitignore or " \
                  "remove it; capturing every test."], lines(run)
  end

  def test_a_control_character_in_a_path_prints_as_a_question_mark
    write_app
    build
    write("app/views/bad\nname.erb", "x\n")
    run = build
    assert_equal [format(CHANGED, "app/views/bad?name.erb")], lines(run)
  end

  # Boot mode (build_via_fork) goes through the same check.
  def test_a_view_edit_captures_every_test_in_boot_mode
    shared = File.expand_path("fixtures/shared_capture", __dir__)
    FileUtils.cp(Dir[File.join(shared, "*.rb")], @root)
    write("data.yml", "a\n")
    git(@root, "init", "-q")
    commit_all(@root, "base")
    Coverage.start(lines: true, methods: true) if Coverage.state == :idle
    Coverage.resume if Coverage.state == :suspended
    boot = lambda do
      map = nil
      _out, err = capture_io do
        map = Mutineer::CoverageMap.new(source_paths: %w[alpha.rb beta.rb], test_paths: %w[alpha_test.rb beta_test.rb],
                                        cache_dir: path(".mutineer"), project_root: @root,
                                        boot_path: path("boot.rb")).build_via_fork
      end
      [map, err]
    end
    boot.call
    map, = boot.call
    refute map.phase_a_ran
    write("data.yml", "b\n")
    map, err = boot.call
    assert map.phase_a_ran
    assert_includes err, format(CHANGED, "data.yml")
  end

  # #604: a file that a test rewrites while the capture runs. The cache saves
  # its fingerprints after the tests ran, so only the record from before the
  # run sees the change. The next run captures every test.
  def write_editor(rel, from, to)
    write("test/z_test.rb", <<~RUBY)
      require "minitest/autorun"
      #{SENTINEL}
      if ENV["PROBE_EDIT"]
        path = File.expand_path(#{"../#{rel}".inspect}, __dir__)
        File.write(path, File.read(path).sub(#{from.inspect}, #{to.inspect}))
      end
      class ZTest < Minitest::Test
        def test_ok; assert true; end
      end
    RUBY
    commit_all
  end

  def build_with_edit(tests)
    ENV["PROBE_EDIT"] = "1"
    build(tests: tests)
  ensure
    ENV.delete("PROBE_EDIT")
  end

  def test_a_source_edited_while_the_capture_runs_captures_every_test_next_run
    write_app
    write_editor("lib/shelf.rb", "    3\n", "    2 + 1\n")
    tests = TESTS + ["test/z_test.rb"]
    build_with_edit(tests)
    run = build(tests: tests)
    assert_equal :full, kind(run, tests)
    assert_equal ["[mutineer] coverage cache: lib/shelf.rb changed while the last run was in progress; capturing every test."],
                 lines(run)
    assert_equal build(cache: ".mutineer/fresh", tests: tests).map.map, run.map.map
  end

  # Edited during the run (A to B), then again before the next run (B to C):
  # no saved print equals C, so only the list that save keeps sees it.
  def test_a_source_edited_during_the_run_and_again_after_it_captures_every_test
    write_app
    write_editor("lib/shelf.rb", "    3\n", "    2 + 1\n")
    tests = TESTS + ["test/z_test.rb"]
    build_with_edit(tests)
    assert_equal ["lib/shelf.rb"], JSON.parse(File.read(path(".mutineer/coverage.json")))["work_tree"]["during_run"]
    write("lib/shelf.rb", File.read(path("lib/shelf.rb")).sub("    2 + 1\n", "    1 + 2\n"))
    run = build(tests: tests)
    assert_equal :full, kind(run, tests)
    assert_equal ["[mutineer] coverage cache: lib/shelf.rb changed while the last run was in progress; capturing every test."],
                 lines(run)
    assert_equal build(cache: ".mutineer/fresh", tests: tests).map.map, run.map.map
  end

  # A boot can edit a source after the caller took the record and before
  # cached_or starts. The record taken again at save sees it; an edit
  # before the next run then cannot reach the partial recapture.
  def test_a_source_edited_during_the_boot_and_again_after_the_run_captures_every_test
    write_app
    record = Mutineer::WorkTree.record(@root)
    write("lib/shelf.rb", File.read(path("lib/shelf.rb")).sub("    3\n", "    2 + 1\n"))
    build(work_tree: record)
    assert_equal ["lib/shelf.rb"], JSON.parse(File.read(path(".mutineer/coverage.json")))["work_tree"]["during_run"]
    write("lib/shelf.rb", File.read(path("lib/shelf.rb")).sub("    2 + 1\n", "    1 + 2\n"))
    run = build
    assert_equal :full, kind(run)
    assert_equal ["[mutineer] coverage cache: lib/shelf.rb changed while the last run was in progress; capturing every test."],
                 lines(run)
  end

  # The same with a commit during the run: the save lists against the
  # recorded commit, so the move of HEAD does not hide the edit.
  def test_a_source_edited_during_the_boot_is_listed_when_head_moves_during_the_run
    write_app
    record = Mutineer::WorkTree.record(@root)
    write("lib/shelf.rb", File.read(path("lib/shelf.rb")).sub("    3\n", "    2 + 1\n"))
    write("README.md", "moved\n")
    git(@root, "commit", "-qm", "docs", "--", "README.md")
    build(work_tree: record)
    assert_equal ["lib/shelf.rb"], JSON.parse(File.read(path(".mutineer/coverage.json")))["work_tree"]["during_run"]
  end

  # When git cannot list the changed files at save, the save cannot tell
  # which source changed during the run, so it lists every one.
  def test_a_git_failure_at_save_lists_every_source_and_test_as_changed_during_the_run
    write_app
    record = Mutineer::WorkTree.record(@root)
    Mutineer::WorkTree.stub(:changed_since, nil) { build(work_tree: record) }
    assert_equal (SOURCES + TESTS).sort, JSON.parse(File.read(path(".mutineer/coverage.json")))["work_tree"]["during_run"]
  end

  def test_a_test_edited_while_the_capture_runs_captures_every_test_next_run
    write_app
    write_editor("test/card_test.rb", "class CardTest", "# edited\nclass CardTest")
    tests = TESTS + ["test/z_test.rb"]
    build_with_edit(tests)
    run = build(tests: tests)
    assert_equal :full, kind(run, tests)
    assert_equal ["[mutineer] coverage cache: test/card_test.rb changed while the last run was in progress; capturing every test."],
                 lines(run)
  end

  # A source edited after its last capture, during the clean check: the
  # cache's loaded-file print is old and its source print is new, and the
  # partial recapture reads only the source print. The record still sees it.
  def test_a_source_edited_during_the_clean_check_captures_every_test_next_run
    write_app
    write("test/z_test.rb", <<~RUBY)
      require "minitest/autorun"
      #{SENTINEL}
      if ENV["PROBE_EDIT"] && !(defined?(Coverage) && Coverage.running?)
        path = File.expand_path("../lib/card.rb", __dir__)
        File.write(path, File.read(path).sub('mode == "strict"', 'mode == "plain"'))
      end
      require_relative "../lib/shelf"
      # It covers a source, so the together check runs it.
      class ZTest < Minitest::Test
        def test_ok; assert_equal 3, Shelf.size; end
      end
    RUBY
    commit_all
    tests = TESTS + ["test/z_test.rb"]
    build_with_edit(tests)
    run = build(tests: tests)
    assert_equal :full, kind(run, tests)
    assert_equal ["[mutineer] coverage cache: lib/card.rb changed while the last run was in progress; capturing every test."],
                 lines(run)
    assert_equal build(cache: ".mutineer/fresh", tests: tests).map.map, run.map.map
  end

  # The loaded-file check saved the helper's fingerprint when the test that
  # loads it ran, before the edit, so that check already sees the change.
  def test_a_loaded_helper_edited_while_the_capture_runs_captures_every_test_next_run
    write_app
    write_editor("lib/util.rb", "= 1\n", "= 2 - 1\n")
    tests = TESTS + ["test/z_test.rb"]
    build_with_edit(tests)
    assert_equal :full, kind(build(tests: tests), tests)
  end
end
