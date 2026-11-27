# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"
require "json"
require "open3"

# Mutineer::WorkTree reads the git state the coverage cache records (#595).
# Each test runs real git in a temporary repository.
class WorkTreeTest < Minitest::Test
  WT = Mutineer::WorkTree

  def git(dir, *args)
    _out, err, status = Open3.capture3("git", "-C", dir, "-c", "user.email=t@example.test", "-c", "user.name=t",
                                       "-c", "commit.gpgsign=false", *args)
    assert status.success?, "git #{args.join(' ')}: #{err}"
  end

  # A repository with one commit: a view, a fixture and a Ruby file.
  def with_repo
    Dir.mktmpdir("mutineer-wt") do |tmp|
      dir = File.realpath(tmp)
      FileUtils.mkdir_p(File.join(dir, "app/views"))
      FileUtils.mkdir_p(File.join(dir, "test/fixtures"))
      File.write(File.join(dir, "app/views/show.html.erb"), "plain\n")
      File.write(File.join(dir, "test/fixtures/cards.yml"), "mode: plain\n")
      File.write(File.join(dir, "card.rb"), "class Card; end\n")
      File.write(File.join(dir, ".gitignore"), "tmp/\n")
      git(dir, "init", "-q")
      git(dir, "add", "-A")
      git(dir, "commit", "-qm", "base")
      yield dir, WT.head(dir)
    end
  end

  def changed(dir, commit) = WT.changed_since(commit, dir).sort

  def test_inside_is_true_in_a_repository_and_false_elsewhere
    with_repo { |dir, _| assert WT.inside?(dir) }
    Dir.mktmpdir { |plain| refute WT.inside?(plain) }
  end

  def test_inside_is_false_in_a_folder_that_an_outer_repository_ignores
    with_repo do |dir, _|
      FileUtils.mkdir_p(File.join(dir, "tmp/app"))
      refute WT.inside?(File.join(dir, "tmp/app"))
      assert_nil WT.head(File.join(dir, "tmp/app"))
    end
  end

  def test_head_is_a_commit_id_or_nil
    with_repo { |_dir, head| assert_match(/\A\h{40,64}\z/, head) }
    Dir.mktmpdir do |dir|
      assert_nil WT.head(dir)
      git(dir, "init", "-q")
      assert_nil WT.head(dir), "a repository with no commit"
    end
  end

  def test_changed_since_lists_edits_staged_edits_deletes_and_untracked_files
    with_repo do |dir, head|
      assert_empty changed(dir, head)
      File.write(File.join(dir, "app/views/show.html.erb"), "strict\n")
      File.write(File.join(dir, "test/fixtures/cards.yml"), "mode: strict\n")
      git(dir, "add", "test/fixtures/cards.yml")
      File.delete(File.join(dir, "card.rb"))
      File.write(File.join(dir, "new.yml"), "x\n")
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      File.write(File.join(dir, "tmp/ignored.yml"), "x\n")
      assert_equal %w[app/views/show.html.erb card.rb new.yml test/fixtures/cards.yml], changed(dir, head)
    end
  end

  def test_changed_since_lists_both_names_of_a_rename_and_a_mode_change
    with_repo do |dir, head|
      git(dir, "mv", "app/views/show.html.erb", "app/views/shown.html.erb")
      File.chmod(0o755, File.join(dir, "card.rb"))
      assert_equal %w[app/views/show.html.erb app/views/shown.html.erb card.rb], changed(dir, head)
    end
  end

  def test_changed_since_reads_names_with_a_space_and_non_ascii_letters
    with_repo do |dir, head|
      File.write(File.join(dir, "my file.yml"), "x\n")
      File.write(File.join(dir, "café.yml"), "x\n")
      got = changed(dir, head)
      assert_equal ["café.yml", "my file.yml"], got
      assert_equal Encoding::UTF_8, got.first.encoding
    end
  end

  def test_changed_since_in_a_subfolder_lists_paths_relative_to_it_and_nothing_outside_it
    with_repo do |dir, head|
      File.write(File.join(dir, "app/views/show.html.erb"), "strict\n")
      File.write(File.join(dir, "card.rb"), "class Card; def x; end; end\n")
      File.write(File.join(dir, "app/new.yml"), "x\n")
      assert_equal %w[new.yml views/show.html.erb], changed(File.join(dir, "app"), head)
    end
  end

  # Git reports no edit to a file with one of these flags, and no removal by
  # a sparse checkout, so each flagged file is listed for a fingerprint.
  def test_changed_since_lists_files_that_git_was_told_not_to_look_at
    with_repo do |dir, head|
      git(dir, "update-index", "--assume-unchanged", "app/views/show.html.erb")
      git(dir, "update-index", "--skip-worktree", "test/fixtures/cards.yml")
      File.write(File.join(dir, "app/views/show.html.erb"), "strict\n")
      File.delete(File.join(dir, "test/fixtures/cards.yml"))
      assert_equal %w[app/views/show.html.erb test/fixtures/cards.yml], changed(dir, head)
      assert_equal "absent", WT.fingerprint(dir, "test/fixtures/cards.yml")
    end
  end

  # git prints a flagged row as a tag, a space and the name. A name that
  # starts with a space keeps it.
  def test_a_flagged_name_that_starts_with_a_space_is_listed_whole
    with_repo do |dir, head|
      File.write(File.join(dir, "  lead.yml"), "a\n")
      git(dir, "add", "--", "  lead.yml")
      git(dir, "commit", "-qm", "lead")
      git(dir, "update-index", "--assume-unchanged", "--", "  lead.yml")
      File.write(File.join(dir, "  lead.yml"), "b\n")
      assert_includes changed(dir, head), "  lead.yml"
      refute_includes changed(dir, head), "lead.yml"
    end
  end

  def test_json_name_keeps_valid_utf8_and_replaces_invalid_bytes_in_either_encoding
    assert_equal "café.yml", WT.json_name("café.yml")
    assert_equal "bad?.yml", WT.json_name("bad\xFF.yml".b)
    assert_equal "bad?.yml", WT.json_name((+"bad\xFF.yml").force_encoding(Encoding::UTF_8))
  end

  def test_changed_since_lists_a_file_that_a_sparse_checkout_removes
    with_repo do |dir, head|
      git(dir, "sparse-checkout", "set", "--no-cone", "/*", "!/app/views/")
      refute File.exist?(File.join(dir, "app/views/show.html.erb"))
      assert_includes changed(dir, head), "app/views/show.html.erb"
    end
  end

  def test_an_unknown_commit_gives_nil_and_is_not_in_the_clone
    with_repo do |dir, head|
      unknown = "#{'0' * 39}1"
      assert_nil WT.changed_since(unknown, dir)
      refute WT.commit?(unknown, dir)
      assert WT.commit?(head, dir)
    end
  end

  def test_a_value_that_is_not_a_commit_id_never_reaches_git
    with_repo do |dir, _head|
      pwned = File.join(dir, "..", "#{File.basename(dir)}-pwned")
      assert_nil WT.changed_since("--output=#{pwned}", dir)
      refute WT.commit?("--output=#{pwned}", dir)
      assert_nil WT.changed_since("HEAD", dir), "a full commit id only"
      refute_path_exists pwned
    end
  end

  def test_an_inherited_git_dir_does_not_change_the_answer
    with_repo do |dir, head|
      Dir.mktmpdir do |other|
        git(other, "init", "-q")
        File.write(File.join(dir, "app/views/show.html.erb"), "strict\n")
        old = ENV.fetch("GIT_DIR", nil)
        ENV["GIT_DIR"] = File.join(other, ".git")
        begin
          assert_equal head, WT.head(dir)
          assert_equal %w[app/views/show.html.erb], changed(dir, head)
        ensure
          old ? ENV["GIT_DIR"] = old : ENV.delete("GIT_DIR")
        end
      end
    end
  end

  def test_a_linked_worktree_answers_for_itself
    with_repo do |dir, head|
      linked = File.join(dir, "..", "#{File.basename(dir)}-linked")
      git(dir, "worktree", "add", "-q", linked)
      linked = File.realpath(linked)
      begin
        File.write(File.join(linked, "app/views/show.html.erb"), "strict\n")
        assert_equal head, WT.head(linked)
        assert_equal %w[app/views/show.html.erb], changed(linked, head)
        assert_empty changed(dir, head)
      ensure
        FileUtils.rm_rf(linked)
      end
    end
  end

  def test_no_git_on_path_gives_no_answer
    with_repo do |dir, head|
      Open3.stub(:capture3, ->(*) { raise Errno::ENOENT, "git" }) do
        refute WT.inside?(dir)
        assert_nil WT.head(dir)
        assert_nil WT.changed_since(head, dir)
        refute WT.commit?(head, dir)
        assert_equal({ "commit" => nil, "dirty" => {} }, WT.record(dir))
      end
    end
  end

  def test_fingerprint_follows_content_mode_links_and_absence
    with_repo do |dir, _|
      rel = "app/views/show.html.erb"
      first = WT.fingerprint(dir, rel)
      File.write(File.join(dir, rel), "strict\n")
      edited = WT.fingerprint(dir, rel)
      refute_equal first, edited
      File.chmod(0o755, File.join(dir, rel))
      refute_equal edited, WT.fingerprint(dir, rel)
      assert_equal "absent", WT.fingerprint(dir, "gone.yml")
      File.symlink("app/views/show.html.erb", File.join(dir, "link.erb"))
      assert_equal "link\0#{Digest::SHA256.hexdigest('app/views/show.html.erb')}", WT.fingerprint(dir, "link.erb")
      assert_nil WT.fingerprint(dir, "app/views"), "a folder never matches"
    end
  end

  # The link target is hashed, so the record is JSON whatever the target's
  # encoding (a US-ASCII file system encoding with LANG unset, #346).
  def test_a_symlink_with_a_non_ascii_target_gives_a_record_json_can_hold
    with_repo do |dir, _|
      File.symlink("café.erb", File.join(dir, "link.erb"))
      target = "caf\xC3\xA9.erb".dup.force_encoding(Encoding::US_ASCII)
      File.stub(:readlink, target) do
        JSON.generate(WT.record(dir))
        assert_match(/\Alink\0\h{64}\z/, WT.fingerprint(dir, "link.erb"))
      end
    end
  end

  def test_record_holds_the_commit_and_a_fingerprint_of_each_changed_path
    with_repo do |dir, head|
      File.write(File.join(dir, "app/views/show.html.erb"), "strict\n")
      record = WT.record(dir)
      assert_equal head, record["commit"]
      assert_equal({ "app/views/show.html.erb" => WT.fingerprint(dir, "app/views/show.html.erb") }, record["dirty"])
    end
  end

  # JSON cannot hold a path that is not UTF-8. The entry is nil, so it never
  # matches, and the record can be saved. Stubbed so it runs on macOS too,
  # where the file system refuses such a name.
  def test_record_saves_a_path_that_is_not_utf8_as_nil
    with_repo do |dir, _|
      bad = "bad\xFF.yml".b
      WT.stub(:changed_since, ->(*) { [bad, "app/views/show.html.erb"] }) do
        record = WT.record(dir)
        assert_nil record["dirty"]["bad?.yml"]
        assert record["dirty"].key?("bad?.yml")
        refute_nil record["dirty"]["app/views/show.html.erb"]
        JSON.generate(record)
      end
    end
  end

  # The daemon loads this file before the app boots. VERSION comes from
  # Bundler's gemspec load under `bundle exec`, not from this file.
  def test_work_tree_loads_alone_with_the_standard_library
    script = 'require "./lib/mutineer/work_tree"; ' \
             'puts (Mutineer.constants - [:VERSION]).sort.join(" ")'
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: File.expand_path("..", __dir__))
    assert status.success?, err
    assert_equal "FsPath WorkTree", out.strip
  end
end
