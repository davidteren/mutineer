# frozen_string_literal: true

require_relative "test_helper"
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

  def pair(root, file)
    path = File.join(root, file)
    source = File.read(path)
    subject = Mutineer::Project.discover([path]).first
    mutation = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source).first
    [Mutineer::MutantId.legacy_for(subject, mutation, source),
     Mutineer::MutantId.for(subject, mutation, source, path: file)]
  end
end
