# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class MutantIdTest < Minitest::Test
  ID = Mutineer::MutantId
  PATH = "lib/x.rb"

  def subject(name: :total, namespace: ["Pricing"], singleton: false)
    Mutineer::Subject.new(file: "x.rb", namespace: namespace, name: name,
                          singleton: singleton, def_node: nil)
  end

  def mutation(src, token, op: :arithmetic, replacement: "-")
    off = src.index(token)
    Mutineer::Mutation.new(start_offset: off, end_offset: off + token.length,
                           replacement: replacement, operator: op)
  end

  def test_deterministic_across_calls
    src = "def total(a, b)\n  a + b\nend\n"
    m = mutation(src, "+")
    assert_equal ID.for(subject, m, src, path: PATH), ID.for(subject, m, src, path: PATH)
  end

  def test_fixed_length_lowercase_hex
    src = "a + b"
    id = ID.for(subject, mutation(src, "+"), src, path: PATH)
    assert_equal 12, id.length
    assert_match(/\A[0-9a-f]{12}\z/, id)
  end

  def test_differs_by_operator
    src = "a + b"
    m1 = mutation(src, "+", op: :arithmetic)
    m2 = mutation(src, "+", op: :literal_mutation)
    refute_equal ID.for(subject, m1, src, path: PATH), ID.for(subject, m2, src, path: PATH)
  end

  def test_differs_by_token
    src = "a + b - c"
    refute_equal ID.for(subject, mutation(src, "+"), src, path: PATH),
                 ID.for(subject, mutation(src, "-"), src, path: PATH)
  end

  def test_differs_by_subject
    src = "a + b"
    m = mutation(src, "+")
    refute_equal ID.for(subject(name: :total), m, src, path: PATH),
                 ID.for(subject(name: :other), m, src, path: PATH)
  end

  def test_differs_by_occurrence
    src = "a + b"
    m = mutation(src, "+")
    refute_equal ID.for(subject, m, src, 0, path: PATH), ID.for(subject, m, src, 1, path: PATH)
  end

  # The core invariant: inserting an unrelated leading line shifts every byte
  # offset, but the id is unchanged because it is keyed on token CONTENT, not the
  # offset — an offset-keyed id would break here.
  def test_invariant_to_leading_inserted_line
    src1 = "a + b"
    src2 = "# an unrelated new comment\na + b"
    assert_equal ID.for(subject, mutation(src1, "+"), src1, path: PATH),
                 ID.for(subject, mutation(src2, "+"), src2, path: PATH)
  end

  # for_subject assigns occurrence so identical (operator, token) twins get
  # distinct ids — e.g. the two `+` in `a + b + c`.
  def test_for_subject_disambiguates_twin_tokens
    src = "a + b + c"
    first = mutation(src, "+")
    second_off = src.index("+", first.start_offset + 1)
    second = Mutineer::Mutation.new(start_offset: second_off, end_offset: second_off + 1,
                                    replacement: "-", operator: :arithmetic)
    ids = ID.for_subject(subject, src, [first, second], path: PATH)
    assert_equal 2, ids.length
    assert_equal 2, ids.uniq.length
  end

  # A mutant's id for the source at `rel` under `root`, found by discovering the
  # file's subjects exactly as a run does.
  def ids_for(root, rel, name)
    file = File.join(root, rel)
    subject = Mutineer::Project.discover([file]).find { |s| s.name == name }
    source = File.read(file)
    mutations = Mutineer::Mutators::Arithmetic.new.mutations_for(subject, source)
    ID.for_subject(subject, source, mutations, path: Mutineer::ProjectPath.relative(file, root))
  end

  def write(root, rel, body)
    FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
    File.write(File.join(root, rel), body)
  end

  # #126: owner-less methods in two files share the qualified name "#label".
  def test_same_ownerless_method_in_two_files_gets_different_ids
    Dir.mktmpdir do |root|
      write(root, "lib/a.rb", "def label(a, b)\n  a + b\nend\n")
      write(root, "lib/b.rb", "def label(a, b)\n  a + b\nend\n")
      refute_equal ids_for(root, "lib/a.rb", :label), ids_for(root, "lib/b.rb", :label)
    end
  end

  # #126: a class reopened in two files shares the qualified name too.
  def test_reopened_class_in_two_files_gets_different_ids
    Dir.mktmpdir do |root|
      body = "class Pricing\n  def total(a, b)\n    a + b\n  end\nend\n"
      write(root, "lib/pricing.rb", body)
      write(root, "lib/pricing/extra.rb", body)
      refute_equal ids_for(root, "lib/pricing.rb", :total), ids_for(root, "lib/pricing/extra.rb", :total)
    end
  end

  def test_path_spellings_and_symlinked_root_give_the_same_path
    Dir.mktmpdir do |dir|
      root = File.join(dir, "real")
      write(root, "lib/x.rb", "x = 1\n")
      link = File.join(dir, "link")
      File.symlink(root, link)
      spellings = [["lib/x.rb", root], ["./lib/x.rb", root], [File.join(root, "lib/x.rb"), root],
                   ["lib/x.rb", link], [File.join(link, "lib/x.rb"), root], [File.join(root, "lib/x.rb"), link]]
      spellings.each do |path, r|
        assert_equal "lib/x.rb", Mutineer::ProjectPath.relative(path, r), "#{path} under #{r}"
      end
    end
  end

  def test_path_spellings_give_the_same_id
    Dir.mktmpdir do |dir|
      root = File.join(dir, "real")
      write(root, "lib/x.rb", "def total(a, b)\n  a + b\nend\n")
      link = File.join(dir, "link")
      File.symlink(root, link)
      assert_equal ids_for(root, "lib/x.rb", :total), ids_for(link, "lib/x.rb", :total)
      assert_equal ids_for(root, "lib/x.rb", :total), ids_for(root, "./lib/x.rb", :total)
    end
  end

  def test_differs_by_path
    src = "a + b"
    m = mutation(src, "+")
    refute_equal ID.for(subject, m, src, path: "lib/a.rb"), ID.for(subject, m, src, path: "lib/b.rb")
  end

  def test_path_is_required
    src = "a + b"
    assert_raises(ArgumentError) { ID.for(subject, mutation(src, "+"), src) }
    assert_raises(ArgumentError) { ID.for_subject(subject, src, [mutation(src, "+")]) }
  end

  # Pinned from the 1.2.0 formula so the legacy id can never drift: stored
  # ignore entries and baselines depend on it.
  def test_legacy_for_reproduces_the_old_format
    src = "def total(a, b)\n  a + b\nend\n"
    m = mutation(src, "+")
    assert_equal "c591d7880fae", ID.legacy_for(subject, m, src)
    assert_equal "b6cff3d44815", ID.legacy_for(subject, m, src, 1)
    assert_equal %w[c591d7880fae b6cff3d44815], ID.legacy_for_subject(subject, src, [m, m])
  end

  def test_edit_outside_the_subject_keeps_ids
    Dir.mktmpdir do |root|
      write(root, "lib/x.rb", "def total(a, b)\n  a + b\nend\n")
      before = ids_for(root, "lib/x.rb", :total)
      write(root, "lib/x.rb", "# new comment\ndef other\n  1 - 2\nend\n\ndef total(a, b)\n  a + b\nend\n")
      assert_equal before, ids_for(root, "lib/x.rb", :total)
    end
  end

  def test_source_outside_the_root_uses_its_absolute_real_path
    Dir.mktmpdir do |dir|
      root = File.join(dir, "project")
      FileUtils.mkdir_p(root)
      write(dir, "elsewhere/x.rb", "x = 1\n")
      outside = File.join(dir, "elsewhere/x.rb")
      rel = Mutineer::ProjectPath.relative(outside, root)
      assert_equal File.realpath(outside), rel
      assert_equal rel, Mutineer::ProjectPath.relative("../elsewhere/x.rb", root)
    end
  end

  # Documented trade-off: ids follow the project root.
  def test_same_file_under_two_roots_gets_different_ids
    Dir.mktmpdir do |root|
      write(root, "lib/x.rb", "def total(a, b)\n  a + b\nend\n")
      refute_equal ids_for(root, "lib/x.rb", :total), ids_for(File.join(root, "lib"), "x.rb", :total)
    end
  end

  # Pinned from this formula before subject_ordinal existed: a subject whose
  # name is unique in its file (ordinal 0) must keep exactly this id.
  def test_subject_ordinal_zero_keeps_the_id
    src = "def total(a, b)\n  a + b\nend\n"
    m = mutation(src, "+")
    assert_equal "e4ac641aa693", ID.for(subject, m, src, path: PATH)
    assert_equal "e4ac641aa693", ID.for(subject, m, src, path: PATH, subject_ordinal: 0)
    assert_equal %w[e4ac641aa693 5af122e61d4f], ID.for_subject(subject, src, [m, m], path: PATH, subject_ordinal: 0)
    refute_equal "e4ac641aa693", ID.for(subject, m, src, path: PATH, subject_ordinal: 1)
    assert_equal ID.for(subject, m, src, path: PATH, subject_ordinal: 1),
                 ID.for_subject(subject, src, [m], path: PATH, subject_ordinal: 1).first
  end

  # Two owner-less `def index` in two DSL blocks of ONE file share the path and
  # the qualified name "#index"; the per-file subject ordinal tells them apart.
  def test_same_name_subjects_in_one_file_get_distinct_ids
    Dir.mktmpdir do |root|
      body = "describe 'a' do\n  def index(a, b)\n    a + b\n  end\nend\n" \
             "describe 'b' do\n  def index(a, b)\n    a + b\n  end\nend\n"
      write(root, "spec/r.rb", body)
      config = Mutineer::Config.new(sources: [File.join(root, "spec/r.rb")], project_root: root)
      jobs, = Mutineer::JobPlan.collect_jobs(config, Mutineer::MutatorRegistry.resolve(%w[arithmetic]))
      assert_equal 2, jobs.size
      assert_equal ["#index"], jobs.map { |j| j[0].qualified_name }.uniq
      assert_equal 2, jobs.map { |j| j[2] }.uniq.size
      # The first subject keeps the id it has without an ordinal.
      assert_equal ids_for(root, "spec/r.rb", :index), [jobs.first[2]]
    end
  end
end
