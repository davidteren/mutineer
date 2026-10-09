# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "set"
require "tmpdir"

# The old-to-new id map and the text rewrite. No process, no tests run.
class MigrateTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # Each old id from the calculator fixture maps to that mutant's new id.
  def test_fixture_source_maps_each_old_id_to_its_new_id
    path = File.join(ROOT, "test/fixtures/calculator.rb")
    config = Mutineer::Config.new(sources: [path], project_root: ROOT, operators: ["arithmetic"])
    current, old_to_new = Mutineer::Migrate.id_maps(config)
    source = File.read(path)
    found = 0
    Mutineer::Project.discover([path]).each do |subject|
      mutations = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source)
      next if mutations.empty?

      news = Mutineer::MutantId.for_subject(subject, source, mutations, path: "test/fixtures/calculator.rb")
      olds = Mutineer::MutantId.legacy_for_subject(subject, source, mutations)
      news.zip(olds) do |new_id, old_id|
        found += 1
        assert_equal [new_id], old_to_new[old_id]
        assert_includes current, new_id
      end
    end
    assert_operator found, :>, 0
    assert_equal found, old_to_new.size
  end

  # The collision fixed in #126: one old id, two files, both new ids.
  def test_an_old_id_shared_by_two_files_maps_to_both_new_ids
    Dir.mktmpdir("mutineer-migrate") do |root|
      %w[a.rb b.rb].each { |file| File.write(File.join(root, file), "class Shared\n  def f(a) = a + 1\nend\n") }
      sources = %w[a.rb b.rb].map { |file| File.join(root, file) }
      config = Mutineer::Config.new(sources: sources, project_root: root, operators: ["arithmetic"])
      current, old_to_new = Mutineer::Migrate.id_maps(config)
      old_a, new_a = pair(root, "a.rb")
      old_b, new_b = pair(root, "b.rb")

      assert_equal old_a, old_b
      refute_equal new_a, new_b
      assert_equal [new_a, new_b], old_to_new[old_a]
      assert_includes current, new_a
      assert_includes current, new_b

      text = "# c\nignore:\n  - #{old_a} # both\nthreshold: 0\n"
      outcome = Mutineer::Migrate.rewrite(text, current, old_to_new)
      assert_equal "# c\nignore:\n  - #{new_a} # both\n  - #{new_b}\nthreshold: 0\n", outcome.text
      assert_equal [old_a], outcome.replacements.map(&:old_id)
      assert_equal [[new_a, new_b]], outcome.replacements.map(&:new_ids)
      assert_empty outcome.unmapped
    end
  end

  # A method renamed since the id was stored matches nothing. The id stays.
  def test_an_id_from_a_renamed_method_is_unmapped
    text = "ignore:\n  - 0123456789ab # renamed\n"
    outcome = Mutineer::Migrate.rewrite(text, Set.new, {})
    assert_equal ["0123456789ab"], outcome.unmapped
    assert_equal text, outcome.text
    assert_empty outcome.replacements
  end

  def test_rewrite_keeps_comments_other_keys_and_is_idempotent
    current = Set["bbbbbbbbbbbb"]
    old_to_new = { "aaaaaaaaaaaa" => ["bbbbbbbbbbbb"] }
    text = "# aaaaaaaaaaaa stays\nbaseline: aaaaaaaaaaaa\nignore:\n  - \"aaaaaaaaaaaa\" # add\n  - bbbbbbbbbbbb\nops: 1\n"
    once = Mutineer::Migrate.rewrite(text, current, old_to_new)
    assert_equal "# aaaaaaaaaaaa stays\nbaseline: aaaaaaaaaaaa\nignore:\n  - \"bbbbbbbbbbbb\" # add\n  - bbbbbbbbbbbb\nops: 1\n", once.text
    twice = Mutineer::Migrate.rewrite(once.text, current, old_to_new)
    assert_equal once.text, twice.text
    assert_empty twice.replacements
    assert_empty twice.unmapped
  end

  def test_flow_list_and_column_zero_item_are_rewritten
    current = Set.new
    old_to_new = { "aaaaaaaaaaaa" => ["bbbbbbbbbbbb"] }
    flow = Mutineer::Migrate.rewrite("ignore: [aaaaaaaaaaaa, cccccccccccc] # note\n", current, old_to_new)
    assert_equal "ignore: [bbbbbbbbbbbb, cccccccccccc] # note\n", flow.text
    assert_equal ["cccccccccccc"], flow.unmapped

    block = Mutineer::Migrate.rewrite("ignore:\n- aaaaaaaaaaaa\nthreshold: 0\n", current, old_to_new)
    assert_equal "ignore:\n- bbbbbbbbbbbb\nthreshold: 0\n", block.text
  end

  # Plan 007 owns `{ id:, reason: }` entries. This rewrite leaves them.
  def test_hash_entry_is_left_untouched
    text = "ignore:\n  - id: aaaaaaaaaaaa\n    reason: later\n"
    outcome = Mutineer::Migrate.rewrite(text, Set.new, { "aaaaaaaaaaaa" => ["bbbbbbbbbbbb"] })
    assert_equal text, outcome.text
    assert_empty outcome.unmapped
    assert_empty outcome.replacements
  end

  # A flow list may put each id on its own line. The whole id changes, and a
  # second run does not change the file again.
  def test_a_multiline_flow_list_rewrites_whole_ids
    current = Set.new
    old_to_new = { "aaaaaaaaaaaa" => ["bbbbbbbbbbbb"], "dddddddddddd" => ["eeeeeeeeeeee"] }
    text = "ignore: [\n  aaaaaaaaaaaa,\n  \"dddddddddddd\", # keep\n  cccccccccccc\n]\n"
    outcome = Mutineer::Migrate.rewrite(text, current, old_to_new)
    assert_equal "ignore: [\n  bbbbbbbbbbbb,\n  \"eeeeeeeeeeee\", # keep\n  cccccccccccc\n]\n", outcome.text
    assert_equal ["cccccccccccc"], outcome.unmapped
    assert_equal %w[aaaaaaaaaaaa dddddddddddd], outcome.replacements.map(&:old_id)

    again = Mutineer::Migrate.rewrite(outcome.text, Set["bbbbbbbbbbbb", "eeeeeeeeeeee"], {})
    assert_equal outcome.text, again.text
    assert_empty again.replacements

    one = Mutineer::Migrate.rewrite("ignore: [\n  aaaaaaaaaaaa\n]\n", current, old_to_new)
    assert_equal "ignore: [\n  bbbbbbbbbbbb\n]\n", one.text

    many = Mutineer::Migrate.rewrite(
      "ignore: ['aaaaaaaaaaaa']\n", Set.new, { "aaaaaaaaaaaa" => %w[bbbbbbbbbbbb cccccccccccc] }
    )
    assert_equal "ignore: ['bbbbbbbbbbbb', 'cccccccccccc']\n", many.text

    noted = Mutineer::Migrate.rewrite("ignore: [\n  aaaaaaaaaaaa # keep\n]\n", current, old_to_new)
    assert_equal "ignore: [\n  bbbbbbbbbbbb # keep\n]\n", noted.text

    spaced = Mutineer::Migrate.rewrite("ignore: [ aaaaaaaaaaaa ]\n", current, old_to_new)
    assert_equal "ignore: [ bbbbbbbbbbbb ]\n", spaced.text
  end

  # An old id inside a longer scalar is not that scalar. A braced entry is
  # not a bare id either, even when its text contains a bracket.
  def test_a_flow_scalar_keeps_an_id_that_is_only_part_of_the_text
    current = Set.new
    old_to_new = { "aaaaaaaaaaaa" => ["bbbbbbbbbbbb"] }
    text = "ignore: [aaaaaaaaaaaa, \"note aaaaaaaaaaaa\", 'also aaaaaaaaaaaa', xxaaaaaaaaaaaayy]\n"
    outcome = Mutineer::Migrate.rewrite(text, current, old_to_new)
    assert_equal "ignore: [bbbbbbbbbbbb, \"note aaaaaaaaaaaa\", 'also aaaaaaaaaaaa', xxaaaaaaaaaaaayy]\n",
                 outcome.text
    assert_equal ["aaaaaaaaaaaa"], outcome.replacements.map(&:old_id)
    assert_empty outcome.unmapped

    braced = "ignore: [aaaaaaaaaaaa, {note: \"] aaaaaaaaaaaa\"}]\n"
    outcome = Mutineer::Migrate.rewrite(braced, current, old_to_new)
    assert_equal "ignore: [bbbbbbbbbbbb, {note: \"] aaaaaaaaaaaa\"}]\n", outcome.text
  end

  # A shape this rewrite cannot read must fail, not exit as if the ids moved.
  def test_an_unsafe_flow_list_is_rejected
    old_to_new = { "aaaaaaaaaaaa" => ["bbbbbbbbbbbb"] }
    {
      "ignore: [\n  aaaaaaaaaaaa,\n" => "closing",
      "ignore: [[aaaaaaaaaaaa]]\n" => "not supported",
      "ignore: [id: aaaaaaaaaaaa]\n" => "not supported",
      "ignore: [\"aa\\naaaaaaaaaa\"]\n" => "not supported"
    }.each do |text, fragment|
      error = assert_raises(ArgumentError, text) do
        Mutineer::Migrate.rewrite(text, Set.new, old_to_new)
      end
      assert_includes error.message, fragment, text
    end
  end

  # A block scalar can hold an id. Leaving it and exiting 0 would hide that.
  def test_a_block_scalar_ignore_is_rejected
    old_to_new = { "aaaaaaaaaaaa" => ["bbbbbbbbbbbb"] }
    [
      "ignore: |\n  aaaaaaaaaaaa\n",
      "ignore: >\n  aaaaaaaaaaaa\n",
      "ignore: |-\n  aaaaaaaaaaaa\n",
      "ignore: | # keep\n  aaaaaaaaaaaa\n",
      "ignore:\n  |\n    aaaaaaaaaaaa\n",
      "ignore:\n\n  |\n    aaaaaaaaaaaa\n",
      "ignore:\n  # note\n  >\n    aaaaaaaaaaaa\n",
      "ignore:\n  - |\n    aaaaaaaaaaaa\n",
      "ignore:\n  - >-\n    aaaaaaaaaaaa\n"
    ].each do |text|
      error = assert_raises(ArgumentError, text) do
        Mutineer::Migrate.rewrite(text, Set.new, old_to_new)
      end
      assert_includes error.message, "block scalar", text
    end

    kept = "ignore:\n  - id: aaaaaaaaaaaa\n    reason: |\n      later\n"
    assert_equal kept, Mutineer::Migrate.rewrite(kept, Set.new, old_to_new).text
  end

  # The new text is written beside the original. A failed write removes that
  # temporary file and leaves the original bytes and mode in place.
  def test_a_failed_config_write_keeps_the_original_file
    Dir.mktmpdir("mutineer-migrate") do |dir|
      path = File.join(dir, ".mutineer.yml")
      File.write(path, "keep: true\n")
      File.chmod(0o640, path)
      paths = []
      File.stub(:write, lambda { |target, _body, **|
        paths << target
        File.open(target, "wb") { |io| io.write("partial") }
        raise Errno::ENOSPC, "no space"
      }) do
        assert_raises(Errno::ENOSPC) { Mutineer::CLI.replace_file(path, "new: true\n") }
      end

      refute_empty paths
      paths.each do |target|
        refute_equal path, target
        assert_equal File.dirname(path), File.dirname(target)
        refute File.exist?(target)
      end
      assert_equal "keep: true\n", File.read(path)
      assert_equal 0o640, File.stat(path).mode & 0o777
      assert_equal [".mutineer.yml"], Dir.children(dir)
    end
  end

  # A link is not the file. The write must change the file the link names.
  def test_replace_file_follows_a_symlink
    Dir.mktmpdir("mutineer-migrate") do |dir|
      target = File.join(dir, "real.yml")
      link = File.join(dir, ".mutineer.yml")
      File.write(target, "old: true\n")
      File.chmod(0o640, target)
      File.symlink(target, link)
      Mutineer::CLI.replace_file(link, "new: true\n")
      assert_equal "new: true\n", File.read(target)
      assert_equal "new: true\n", File.read(link)
      assert File.symlink?(link)
      assert_equal 0o640, File.stat(target).mode & 0o777
      assert_equal [".mutineer.yml", "real.yml"], Dir.children(dir).sort
    end
  end

  def test_replace_file_keeps_the_mode_and_replaces_the_text
    Dir.mktmpdir("mutineer-migrate") do |dir|
      path = File.join(dir, ".mutineer.yml")
      File.write(path, "old: true\n")
      File.chmod(0o640, path)
      Mutineer::CLI.replace_file(path, "new: true\n")
      assert_equal "new: true\n", File.read(path)
      assert_equal 0o640, File.stat(path).mode & 0o777
      assert_equal [".mutineer.yml"], Dir.children(dir)
    end
  end

  def pair(root, file)
    path = File.join(root, file)
    source = File.read(path)
    subject = Mutineer::Project.discover([path]).first
    mutation = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first
    [Mutineer::MutantId.legacy_for(subject, mutation, source),
     Mutineer::MutantId.for(subject, mutation, source, path: file)]
  end
end
